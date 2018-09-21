{-# LANGUAGE TemplateHaskell #-}

-- | Module contains the definition of Educator's WorkMode and its implementations.

module Dscp.Educator.Launcher.Mode
    (
      -- * Markers
      EducatorNode

      -- * Constraints
    , EducatorWorkMode
    , CombinedWorkMode

      -- * Implementations
    , EducatorContext (..)
    , EducatorRealMode
    , ecWitnessCtx
    ) where

import Control.Lens (makeLenses)
import Loot.Base.HasLens (HasLens (..), HasLens')
import Loot.Log.Rio (LoggingIO)
import Loot.Network.ZMQ as Z

import Dscp.DB.Rocks.Real.Types (RocksDB)
import Dscp.DB.SQLite (SQLiteDB)
import Dscp.Educator.Config (HasEducatorConfig, withEducatorConfig)
import Dscp.Educator.Launcher.Marker (EducatorNode)
import Dscp.Educator.Launcher.Resource (EducatorResources)
import qualified Dscp.Launcher.Mode as Basic
import Dscp.Resource.Keys (KeyResources)
import Dscp.Rio (RIO)
import Dscp.Snowdrop.Actions (SDVars)
import qualified Dscp.Witness as W
import Dscp.Witness.Mempool (MempoolVar)
import Dscp.Witness.Relay

---------------------------------------------------------------------
-- WorkMode class
---------------------------------------------------------------------

-- | Set of typeclasses which define capabilities of bare Educator node.
type EducatorWorkMode ctx m =
    ( Basic.BasicWorkMode m

    , HasEducatorConfig

    , MonadReader ctx m

    , HasLens' ctx SQLiteDB
    , HasLens' ctx (KeyResources EducatorNode)
    , MonadThrow m
    )

-- | Set of typeclasses which define capabilities both of Educator and Witness.
type CombinedWorkMode ctx m =
    ( EducatorWorkMode ctx m
    , W.FullWitnessWorkMode ctx m
    )

---------------------------------------------------------------------
-- WorkMode implementation
---------------------------------------------------------------------

-- TODO add parameters
-- TODO Separate resources and non-resources.
data EducatorContext = EducatorContext
    { _ecResources  :: !EducatorResources
      -- ^ Resources, allocated from params.
    , _ecWitnessCtx :: !W.WitnessContext
    }

makeLenses ''EducatorContext

type EducatorRealMode = RIO EducatorContext

---------------------------------------------------------------------
-- HasLens
---------------------------------------------------------------------

instance HasLens SQLiteDB EducatorContext SQLiteDB where
    lensOf = ecResources . lensOf @SQLiteDB
instance HasLens (KeyResources EducatorNode) EducatorContext (KeyResources EducatorNode) where
    lensOf = ecResources . lensOf @(KeyResources EducatorNode)

instance HasLens LoggingIO EducatorContext LoggingIO where
    lensOf = ecWitnessCtx . lensOf @LoggingIO
instance HasLens RocksDB EducatorContext RocksDB where
    lensOf = ecWitnessCtx . lensOf @RocksDB
instance HasLens Z.ZTGlobalEnv EducatorContext Z.ZTGlobalEnv where
    lensOf = ecWitnessCtx . lensOf @Z.ZTGlobalEnv
instance HasLens Z.ZTNetCliEnv EducatorContext Z.ZTNetCliEnv where
    lensOf = ecWitnessCtx . lensOf @Z.ZTNetCliEnv
instance HasLens Z.ZTNetServEnv EducatorContext Z.ZTNetServEnv where
    lensOf = ecWitnessCtx . lensOf @Z.ZTNetServEnv
instance HasLens (KeyResources W.WitnessNode) EducatorContext (KeyResources W.WitnessNode) where
    lensOf = ecWitnessCtx . lensOf @(KeyResources W.WitnessNode)
instance HasLens MempoolVar EducatorContext MempoolVar where
    lensOf = ecWitnessCtx . lensOf @MempoolVar
instance HasLens SDVars EducatorContext SDVars where
    lensOf = ecWitnessCtx . lensOf @SDVars
instance HasLens RelayState EducatorContext RelayState where
    lensOf = ecWitnessCtx . lensOf @RelayState
instance HasLens W.SDLock EducatorContext W.SDLock where
    lensOf = ecWitnessCtx . lensOf @W.SDLock

----------------------------------------------------------------------------
-- Sanity check
----------------------------------------------------------------------------

_sanity :: EducatorRealMode ()
_sanity = withEducatorConfig (error "") $ W.withWitnessConfig (error "") _sanityCallee
  where
    _sanityCallee :: CombinedWorkMode ctx m => m ()
    _sanityCallee = pass
