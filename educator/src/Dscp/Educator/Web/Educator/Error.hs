-- | Educator API errors

module Dscp.Educator.Web.Educator.Error
       ( APIError (..)

       , ErrResponse (..)

       , DSON

       , toServantErr
       , unexpectedToServantErr
       ) where

import Control.Lens (makePrisms)
import Data.Aeson (ToJSON (..), Value (..), encode)
import Data.Aeson.Options (defaultOptions)
import Data.Aeson.TH (deriveToJSON)
import Data.Reflection (Reifies (..))
import Data.Typeable (cast)
import Dscp.DB.SQLite (DomainError, SQLRequestsNumberExceeded)
import Servant (ServantErr (..), err400, err500, err503)

import Dscp.Educator.Web.Util
import Dscp.Util.Servant

-- | Any error backend may return.
data APIError
    = SomeDomainError DomainError
      -- ^ Something not found or already exists.
    | InvalidFormat
      -- ^ Failed to decode something.
    | ServiceUnavailable !Text
      -- ^ Service is overloaded with requests.
    deriving (Show, Eq, Generic)

makePrisms ''APIError

instance Exception APIError where
    fromException e@(SomeException e') =
        asum
        [ cast e'
        , SomeDomainError <$> fromException e
        , ServiceUnavailable . pretty @SQLRequestsNumberExceeded <$> fromException e
        ]

-- | Contains info about error in client-convenient form.
data ErrResponse = ErrResponse
    { erError :: !APIError
    } deriving (Show, Eq, Generic)

---------------------------------------------------------------------------
-- JSON instances
---------------------------------------------------------------------------

deriveToJSON defaultOptions ''ErrResponse

instance ToJSON APIError where
    toJSON = String . \case
        InvalidFormat        -> "InvalidFormat"
        SomeDomainError err  -> domainErrorToShortJSON err
        ServiceUnavailable{} -> "ServiceUnavailable"

---------------------------------------------------------------------------
-- Functions
---------------------------------------------------------------------------

-- | Get HTTP error code of error.
toServantErrNoReason :: APIError -> ServantErr
toServantErrNoReason = \case
    InvalidFormat        -> err400
    ServiceUnavailable{} -> err503
    SomeDomainError err  -> domainToServantErrNoReason err

-- | Make up error which will be returned to client.
toServantErr :: APIError -> ServantErr
toServantErr err = (toServantErrNoReason err){ errBody = encode $ ErrResponse err }

-- | Map any (unknown) error to servant error.
unexpectedToServantErr :: SomeException -> ServantErr
unexpectedToServantErr err = err500{ errBody = show err }

---------------------------------------------------------------------------
-- Other
---------------------------------------------------------------------------

data FaucetDecodeErrTag
instance Reifies FaucetDecodeErrTag String where
    reflect _ = decodeUtf8 $ encode InvalidFormat

-- | Marker like 'JSON' for servant, but returns just "InvalidFormat" on
-- decoding error.
type DSON = SimpleJSON FaucetDecodeErrTag
