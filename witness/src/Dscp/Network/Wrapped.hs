{-# LANGUAGE ExistentialQuantification #-}

-- Some of these methods have 'NetworkingX' constraint added though it is
-- not required. I use it to force fundep m -> t so user can use methods
-- without specifying t.

-- | High-level typed wrapper over loot-network, is supposed to be
-- used within the library instead of loot-network directly.

module Dscp.Network.Wrapped
    (
      NetTag

    , MsgK
    , SubK
    , msgType
    , fromMsgType
    , subType
    , fromSubType

    , Listener (..)
    , hoistListener
    , runListener
    , withListeners
    , servSend
    , servPub
    , simpleListener
    , lcallback

    , Worker
    , wIdL
    , simpleWorker
    , bootingWorker
    , bootingWorker_
    , netWorker
    , hoistWorker
    , runWorker
    , withWorkers
    , cliSend
    , CliRecvExc(..)
    , cliRecv
    , cliRecvResp
    , cliRecvUpdate
    , ccallback

    , withClient
    , withServer

      -- reexports
    , ListenerEnv
    , ClientEnv
    , CallbackWrapper
    , NodeId
    , handlerDecoded
    ) where


import Codec.Serialise (serialise)
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (orElse, retry)
import Control.Concurrent.STM.TMVar (newEmptyTMVarIO, putTMVar, readTMVar)
import Control.Lens (makeLensesWith)
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BSL
import Fmt ((+||), (||+))
import Loot.Log (MonadLogging, logDebug, logError, logWarning)
import Loot.Network.BiTQueue (recvBtq, sendBtq)
import Loot.Network.Class (CliId, ClientEnv, ClientId, ListenerEnv, ListenerId, MsgType (..),
                           NetworkingCli, NetworkingServ, NodeId, Subscription (..), registerClient,
                           registerListener, runClient, runServer)
import qualified Loot.Network.Class as L
import Loot.Network.Message (CallbackWrapper, Message (..), getMsgTag, handlerDecoded,
                             handlerDecoded, runCallbacksInt)
import Loot.Network.ZMQ.Common (ZmqTcp)
import Time (sec)
import UnliftIO (MonadUnliftIO)
import UnliftIO.Async (Async, async, cancel, withAsync)

import Dscp.Util
import Dscp.Util.TimeLimit
import Dscp.Util.Timing

----------------------------------------------------------------------------
-- Common
----------------------------------------------------------------------------

-- | We use ZmqTcp all over the project. If one wants to change it,
-- they should change 'NetTag' first.
type NetTag = ZmqTcp

----------------------------------------------------------------------------
-- Messages
----------------------------------------------------------------------------

-- | Tag for messages which are "real communication messages".
data MsgK

-- | Tag for subscription messages.
data SubK

-- | Get a 'MsgType' related to the message specified (pack the
-- natural which is related to the message type).
msgType :: forall d. (Message MsgK d) => MsgType
msgType = MsgType $ BS8.pack $ show $ getMsgTag @MsgK @d

-- | Convert 'MsgType' to a natural number.
fromMsgType :: MsgType -> Maybe Natural
fromMsgType (MsgType bs) = readMaybe (BS8.unpack bs)

-- | Same as 'msgType', but for subscriptions.
subType :: forall d. (Message SubK d) => Subscription
subType = Subscription $ BS8.pack $ show $ getMsgTag @SubK @d

-- | Same as 'fromMsgType', but for subscriptions.
fromSubType :: Subscription -> Maybe Natural
fromSubType (Subscription bs) = readMaybe (BS8.unpack bs)

---------------------------------------------------------------------------
-- Listeners
----------------------------------------------------------------------------

-- Listeners are supposed to have one dispatcher only (and one receive
-- block only). When new messages come, response callback thread is
-- forked and this thread is allowed to send multiple messages
-- (directly, or publish).

data Listener m = Listener
    { lId       :: !ListenerId
      -- ^ Listener id, should be unique.
    , lMsgTypes :: !(Set MsgType)
      -- ^ Message types listener is supposed to receive.
    , lAction   :: !(ListenerEnv NetTag -> m Void)
      -- ^ Listener's action. Should never terminate.
    }

hoistListener :: (forall a. m a -> n a) -> Listener m -> Listener n
hoistListener f li = li{ lAction = f . lAction li }

runListener ::
       forall m. (NetworkingServ NetTag m, MonadLogging m, MonadMask m, MonadUnliftIO m)
    => Listener m
    -> m (Async Void)
runListener Listener{..} = do
    logDebug $ "Launching listner " +|| lId ||+ ""
    (lEnv :: ListenerEnv NetTag) <- registerListener @NetTag lId lMsgTypes
    async $ loop lEnv
              `finally` (logDebug $ "Listener " +|| lId ||+ " has exited")
  where
    loop env =
        lAction env `catchAny` \e -> do
            logError $ "Listener " +|| lId ||+ " stopped due to error: " +|| e ||+ ""
            lAction env

withListeners
    :: (NetworkingServ NetTag m, MonadMask m, MonadLogging m, MonadUnliftIO m)
    => m [Listener m] -> m a -> m a
withListeners listenersM action = do
    listeners <- listenersM
    bracket
        (mapM (\l -> (l, ) <$> async (runListener l)) listeners)
        (mapM terminate)
        $ \_ -> action
  where
    terminate (listener, listenerAsync) =
        logWarningWaitInf (sec 1) ("Listener " <> show (lId listener) <> " shutdown") $
        cancel listenerAsync

servSend :: forall d. Message MsgK d => ListenerEnv NetTag -> CliId NetTag -> d -> STM ()
servSend btq cliId msg =
    sendBtq btq $ L.Reply cliId (msgType @d) [BSL.toStrict $ serialise msg]

servPub :: forall d. Message SubK d => ListenerEnv NetTag -> d -> STM ()
servPub btq msg =
    sendBtq btq $ L.Publish (subType @d) [BSL.toStrict $ serialise msg]

simpleListener ::
       forall m. (MonadIO m, MonadMask m, MonadLogging m)
    => ListenerId
    -> Set MsgType
    -> (ListenerEnv NetTag -> [CallbackWrapper (CliId NetTag) m ()])
    -> Listener m
simpleListener lId lMsgTypes getCallbacks =
    Listener {..}
  where
    -- todo use 'fmt' or something similar
    lAction btq = do
        logDebug $ "Listener " +|| lId ||+ " has started."
        forever $
            recoverAll ("Listener " +|| lId ||+ "") (constDelay (sec 2)) (action btq)
    action btq = do
        let callbacks = getCallbacks btq
        (cliId,msgT,content) <- atomically $ recvBtq btq
        case (fromMsgType msgT,content) of
            (Just n,[d]) -> runCallbacksInt callbacks n d cliId >>= \case
                Nothing ->
                    logWarning $ "Listener " +|| lId ||+ "couldn't match on type (runCallbacksInt)"
                _       -> pass
            _            -> pass

-- for server, we just skip the message if we can't decode it, since
-- we have only one dispatcher.
lcallback ::
       forall d m. (Message MsgK d, Monad m)
    => (CliId NetTag -> d -> m ())
    -> CallbackWrapper (CliId NetTag) m ()
lcallback foo = handlerDecoded $ \cId -> either (const $ pass) (foo cId)

----------------------------------------------------------------------------
-- Workers
----------------------------------------------------------------------------

data Worker m = forall pre. Worker
    { wId        :: !ClientId
      -- ^ Worker's identity.
    , wBootstrap :: m pre
      -- ^ Initialize necessary context. Fail here or never.
    , wAction    :: !(pre -> m Void)
      -- ^ Worker's action. Should never end.
    }

makeLensesWith postfixLFields ''Worker

-- | An action which will happen forever.
simpleWorker :: Monad m => ClientId -> m () -> Worker m
simpleWorker wId action = bootingWorker_ wId pass action

-- | A worker with one-shot bootstrap and infinite main action.
bootingWorker_ :: Monad m => ClientId -> m () -> m () -> Worker m
bootingWorker_ wId boot action = bootingWorker wId boot (\() -> action)

-- | A worker with context preparation.
bootingWorker :: Monad m => ClientId -> m a -> (a -> m ()) -> Worker m
bootingWorker wId boot action = Worker wId boot (forever . action)

netWorker
    :: NetworkingCli NetTag m
    => ClientId
    -> Set MsgType
    -> Set Subscription
    -> (ClientEnv NetTag -> m ())
    -> Worker m
netWorker cId msgTypes subs action =
    bootingWorker cId register action
  where
    register = registerClient @NetTag cId msgTypes subs

hoistWorker :: (forall a. m a -> n a) -> Worker m -> Worker n
hoistWorker f Worker{..} =
    Worker
    { wBootstrap = f wBootstrap
    , wAction = \pre -> f $ wAction pre
    , ..
    }

runWorker ::
       forall m. (MonadMask m, MonadLogging m, MonadUnliftIO m)
    => Worker m
    -> m (Async Void)
runWorker Worker{..} = do
    logDebug $ "Launching worker " +|| wId ||+ ""
    pre <- wBootstrap
    async $ loop pre
              `finally` (logDebug $ "Worker " +|| wId ||+ " has exited")
  where
    loop pre =
        wAction pre `catchAny` \e -> do
            logError $ "Worker " +|| wId ||+ " stopped due to error: " +|| e ||+ ""
            wAction pre

withWorkers
    :: (MonadMask m, MonadLogging m, MonadUnliftIO m)
    => m [Worker m] -> m a -> m a
withWorkers workersM action = do
    workers <- workersM
    bracket
        (mapM (\w -> (w, ) <$> runWorker w) workers)
        (mapM terminate)
        $ \_ -> action
  where
    terminate (worker, workerAsync) =
        logWarningWaitInf (sec 1) ("Worker " <> show (wId worker) <> " shutdown") $
        cancel workerAsync

cliSend ::
       forall d m. (Message MsgK d, NetworkingCli NetTag m, MonadIO m)
    => ClientEnv NetTag
    -> Maybe (NodeId NetTag)
    -> d
    -> m ()
cliSend btq nId msg =
    atomically $ sendBtq btq (nId, (msgType @d, [BSL.toStrict $ serialise msg]))

data CliRecvExc
    = CRETimeout
    | CREUnexpected Text
    | CREMalformed Text
    deriving (Eq, Show, Generic)

instance Exception CliRecvExc

data CliRecvExcInternal
    = CREMalformedTag
    | CRENoCallback Natural
    | CREWrongFramesNumber Int
    deriving (Eq,Show,Generic)

instance Exception CliRecvExcInternal

type SendConstraint k d m
     = ( Message k d
       , NetworkingCli NetTag m
       , MonadUnliftIO m
       , MonadCatch m
       , MonadLogging m)

-- Timeout -- milliseconds, 0 if instant response is expected, -1 (any
-- negative) if timeout should be disabled.
--
-- Callback takes care of decoding itself because we might want to
-- propagate data first (before decoding the message).
cliRecv ::
       forall m a.
       ( NetworkingCli NetTag m
       , MonadUnliftIO m
       , MonadCatch m
       , MonadLogging m)
    => ClientEnv NetTag
    -> Int
    -> [CallbackWrapper (NodeId NetTag) m a]
    -> m a
cliRecv btq timeout callbacks = withHandler $ withTimeout $ \tmAction -> do
    res <- atomically $ (Right <$> recvBtq btq) `orElse` (Left <$> tmAction)
    let call nId msgTagM msgs = do
            msgTag <- maybe (throwM CREMalformedTag) pure msgTagM
            msg <- case msgs of
                [x]   -> pure x
                other -> throwM $ CREWrongFramesNumber (length other)
            runCallbacksInt callbacks msgTag msg nId >>= \case
                Nothing -> throwM $ CRENoCallback msgTag
                Just x -> pure x
    case res of
        Right (nId, L.Response msgT msg) -> call nId (fromMsgType msgT) msg
        Right (nId, L.Update sub msg)    -> call nId (fromSubType sub) msg
        Left ()                          -> throwM CRETimeout
  where
    withHandler x =
        catch x $ \(e :: CliRecvExcInternal) -> do
            logWarning $ "Could not receive: " +|| e ||+ ", retrying"
            case e of
                CRENoCallback n -> throwM $ CREUnexpected $ "No callback for " <> show n
                -- we ignore messages related to malformed input from
                -- the network (just warn)
                _               -> withHandler x

    withTimeout :: (STM () -> m x) -> m x
    withTimeout action
        | timeout < 0 = action retry
        | otherwise = do
              timeoutVar <- liftIO newEmptyTMVarIO
              let timer = do
                      liftIO $ threadDelay timeout
                      atomically $ putTMVar timeoutVar ()
              withAsync timer $ \_async -> action (readTMVar timeoutVar)

cliRecvOne ::
       forall k d m. SendConstraint k d m
    => ClientEnv NetTag
    -> Int
    -> m (NodeId NetTag, d)
cliRecvOne btq timeout =
    cliRecv
        btq
        timeout
        [ handlerDecoded $ \(nId :: NodeId NetTag) ->
              either (\e -> throwM $ CREMalformed $ "cliRecvOne parse error " <> show e)
                     (pure . (nId,))
        ]

-- | Receive a response.
cliRecvResp ::
       forall d m. SendConstraint MsgK d m
    => ClientEnv NetTag
    -> Int
    -> m (NodeId NetTag, d)
cliRecvResp = cliRecvOne @MsgK @d

-- | Receive an update.
cliRecvUpdate ::
       forall d m. SendConstraint SubK d m
    => ClientEnv NetTag
    -> Int
    -> m (NodeId NetTag, d)
cliRecvUpdate = cliRecvOne @SubK @d

-- Callback printing a warning if it can't decode the result.
ccallback ::
       forall d k m. (Message k d, MonadLogging m, Monad m)
    => (NodeId NetTag -> d -> m ())
    -> CallbackWrapper (NodeId NetTag) m ()
ccallback foo =
    handlerDecoded $ \cId -> either (\e -> logWarning $ "ccallback: " +|| e ||+ "") (foo cId)

----------------------------------------------------------------------------
-- Launching
----------------------------------------------------------------------------

-- | Launch client broker on the background.
withClient :: (MonadUnliftIO m, NetworkingCli NetTag m) => m a -> m a
withClient = withAsync runClient . const

-- | Launch server and client brokers on the background.
withServer :: (MonadUnliftIO m, NetworkingServ NetTag m, NetworkingCli NetTag m) => m a -> m a
withServer = withAsync runServer . const . withAsync runClient . const
