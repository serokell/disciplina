{-# LANGUAGE OverloadedLists #-}

module Dscp.MultiEducator.Workers
    ( multiEducatorWorkers
    ) where

import qualified Control.Concurrent.STM as STM
import qualified Data.Map as M
import Loot.Base.HasLens (lensOf)
import Loot.Config (option, sub)
import Serokell.Util (modifyTVarS)
import Time (minute, sec, threadDelay, timeAdd)
import UnliftIO (handle)

import Dscp.MultiEducator.Config
import Dscp.MultiEducator.Launcher.Context
import Dscp.MultiEducator.Launcher.Educator
import Dscp.MultiEducator.Launcher.Mode
import Dscp.Network
import Dscp.Util.Time

multiEducatorWorkers
    :: MultiEducatorWorkMode ctx m
    => [Client m]
multiEducatorWorkers =
    [ privateBlockCreatorWorker
    ]

----------------------------------------------------------------------------
-- Educator contexts expiration
----------------------------------------------------------------------------

privateBlockCreatorWorker :: MultiEducatorWorkMode ctx m => Client m
privateBlockCreatorWorker =
    simpleWorker "expiredEducatorsUnload" $ do
        educatorContexts <- view $ lensOf @MultiEducatorResources . merEducatorData

        handleTerminatedException . forever $ do
            -- TODO: insert logWaitLongAction
            time <- getCurTime
            let isExpired = \case
                    LockedEducatorContext -> False
                    FullyLoadedEducatorContext ctx -> and @[_]
                        [ expiryDuration `timeAdd` lecLastActivity ctx > time
                        , null (lecUsers ctx)
                        ]

            -- Phase 1: remove all expired contexts

            expiredCtxs <- atomically . modifyTVarS educatorContexts . onTerminatedThrow $ do
                ctxMap <- get
                ctxReadMap <- lift $ forM ctxMap $ \ctxVar -> (ctxVar, ) <$> readTVar ctxVar
                let (expired, nonExpired) = M.partition (isExpired . snd) ctxReadMap
                put (fmap fst nonExpired)
                return (snd <$> M.elems expired)

            -- TODO: there is a major problem: right here there is a probability
            -- to get another request to server using expired context, and eventually
            -- this request may be killed along with the context unload and this is very undesired.

            forM_ expiredCtxs $ \case
                LockedEducatorContext -> error "impossible"
                FullyLoadedEducatorContext ctx -> unloadEducator ctx

            -- Phase 2: wait for the next expiring context

            nextExpiry <- atomically . modifyTVarS educatorContexts . onTerminatedThrow $ do
                ctxs <- gets M.elems
                las <- lift $ forM ctxs $ fmap lastActivity . readTVar
                when (null las) $ lift STM.retry
                return $ timeAdd expiryDuration (minimum las)

            let tillNextExpiry = nextExpiry `timeDiffNonNegative` time
            sleep $ max minimalCheckPeriod tillNextExpiry
  where
    lastActivity = \case
        LockedEducatorContext -> infiniteFuture
        FullyLoadedEducatorContext ctx -> lecLastActivity ctx
    expiryDuration = multiEducatorConfig ^. sub #educator . option #contextExpiry
    minimalCheckPeriod = sec 1
    handleTerminatedException =
        handle $ \MultiEducatorIsTerminating ->
            -- waiting for this worker to be killed outside
            forever $ threadDelay (minute 1)
