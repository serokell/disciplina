-- | Starting point for running a Witness node

module Main where

import Control.Concurrent (threadDelay)
import Loot.Log (logInfo, logWarning, modifyLogName)
import Options.Applicative (execParser, fullDesc, helper, info, progDesc)
import UnliftIO.Async (async)

import Dscp.CommonCLI (versionOption)
import Dscp.Config (buildConfig, configPathParser)
import Dscp.Network (runListener, runWorker, withServer)
import Dscp.Witness


main :: IO ()
main = do
    (witnessParams, wConfig) <- getWitnessParams
    launchWitnessRealMode wConfig witnessParams $
        withServer $
        modifyLogName (<> "node") $ do
            logInfo "Starting node."

            logInfo "Forking workers"
            forM_ witnessWorkers $ void . async . runWorker identity

            logInfo "Forking listeners"
            forM_ witnessListeners $ void . async . runListener identity

            logInfo "Forking wallet server"
            void . async $
                serveWitnessAPIReal (wpWalletServerParams witnessParams)

            logInfo "All done"
            logInfo "Hey, here log-warper works!"
            logWarning "Don't forget to implement everything else though!"
            forever $ liftIO $ threadDelay 10000000

getWitnessParams :: IO (WitnessParams, WitnessConfigRec)
getWitnessParams = do
    let parser = (,) <$> witnessParamsParser <*> configPathParser
    (params, configPath) <- execParser $
        info (helper <*> versionOption <*> parser) $
        fullDesc <> progDesc "Disciplina witness node."
    config <- buildConfig configPath fillWitnessConfig
    return (params, config)
