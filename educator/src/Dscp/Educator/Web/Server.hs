{-# LANGUAGE TypeOperators #-}

-- | Functions to serve Student HTTP API

module Dscp.Educator.Web.Server
       ( serveEducatorAPIsReal
       ) where

import Data.Proxy (Proxy (..))
import Fmt ((+|), (|+))
import Loot.Base.HasLens (lensOf)
import Loot.Log (logInfo)
import Network.HTTP.Types.Header (hAuthorization, hContentType)
import Network.Wai.Middleware.Cors (CorsResourcePolicy (..), cors, simpleCorsResourcePolicy)
import Servant ((:<|>) (..), Context (..), Handler, ServantErr (..), Server, err405,
                hoistServerWithContext, serveWithContext)
import Servant.Auth.Server.Internal.ThrowAll (throwAll)
import Servant.Generic (toServant)
import UnliftIO (askUnliftIO)

import Dscp.Crypto (PublicKey, keyGen, withIntSeed)
import Dscp.Educator.Launcher.Mode (CombinedWorkMode, EducatorNode, EducatorWorkMode)
import Dscp.Educator.Web.Bot (EducatorBotSwitch (..), addBotHandlers, initializeBot)
import Dscp.Educator.Web.Educator (EducatorPublicKey (..), ProtectedEducatorAPI,
                                   convertEducatorApiHandler, educatorApiHandlers,
                                   protectedEducatorAPI)
import Dscp.Educator.Web.Params (EducatorWebParams (..))
import Dscp.Educator.Web.Student (GetStudentsAction (..), ProtectedStudentAPI,
                                  convertStudentApiHandler, studentAPI, studentApiHandlers)
import Dscp.Resource.Keys (KeyResources, krPublicKey)
import Dscp.Web (ServerParams (..), serveWeb)
import Dscp.Witness.Web

type EducatorWebAPI =
    ProtectedEducatorAPI
    :<|>
    ProtectedStudentAPI
    :<|>
    WitnessAPI

mkEducatorApiServer
    :: forall ctx m. EducatorWorkMode ctx m
    => (forall x. m x -> Handler x)
    -> Server ProtectedEducatorAPI
mkEducatorApiServer nat =
    hoistServerWithContext
        protectedEducatorAPI
        (Proxy :: Proxy '[EducatorPublicKey])
        nat
        (\() -> toServant educatorApiHandlers)

mkStudentApiServer
    :: forall ctx m. EducatorWorkMode ctx m
    => (forall x. m x -> Handler x)
    -> EducatorBotSwitch
    -> m (Server ProtectedStudentAPI)
mkStudentApiServer nat botSwitch = do
    case botSwitch of
      EducatorBotOff -> return $ getServer . studentApiHandlers
      EducatorBotOn params -> initializeBot params $ do
        return $ (\student -> getServer . addBotHandlers student . studentApiHandlers $ student)
  where
    getServer handlers = hoistServerWithContext
        studentAPI
        (Proxy :: Proxy '[GetStudentsAction])
        nat
        (toServant handlers)

-- This is a temporary function that provides a dummy GetStudentAction
createGetStudentsAction :: IO GetStudentsAction
createGetStudentsAction = do
    (tvr :: TVar [PublicKey]) <- atomically $ newTVar []
    let addKeyWithSeed n =
            let pk = snd $ withIntSeed n keyGen
            in atomically $ modifyTVar' tvr (pk:)
    traverse_ addKeyWithSeed [1000..1100]
    return . GetStudentsAction $ atomically . readTVar $ tvr

serveEducatorAPIsReal :: CombinedWorkMode ctx m => Bool -> EducatorWebParams -> m ()
serveEducatorAPIsReal withWitnessApi EducatorWebParams{..} = do
    let ServerParams{..} = ewpServerParams
    educatorKeyResources <- view (lensOf @(KeyResources EducatorNode))
    getStudents <- liftIO $ createGetStudentsAction
    let educatorPublicKey = EducatorPublicKey $ educatorKeyResources ^. krPublicKey
    let srvCtx = educatorPublicKey :. getStudents :. EmptyContext

    logInfo $ "Serving Student API on "+|spAddr|+""
    unliftIO <- askUnliftIO
    let educatorApiServer = mkEducatorApiServer (convertEducatorApiHandler unliftIO)
    studentApiServer <- mkStudentApiServer (convertStudentApiHandler unliftIO) ewpBotParams
    let witnessApiServer = if withWitnessApi
          then mkWitnessAPIServer (convertWitnessHandler unliftIO)
          else throwAll err405{ errBody = "Witness API disabled at this port" }
    let ourCors = cors (const $ Just $
                        simpleCorsResourcePolicy
                        { corsRequestHeaders = [hContentType, hAuthorization] })
    serveWeb spAddr $
      ourCors $
      serveWithContext (Proxy @EducatorWebAPI) srvCtx $
         educatorApiServer
         :<|>
         studentApiServer
         :<|>
         witnessApiServer
