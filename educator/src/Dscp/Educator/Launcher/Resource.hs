{-# LANGUAGE OverloadedLabels #-}

-- | Resources used by Educator node

module Dscp.Educator.Launcher.Resource
       ( EducatorResources (..)
       , erWitnessResources
       ) where

import Control.Lens (makeLenses)
import Fmt ((+|), (|+))
import Loot.Log (logDebug)
import qualified Pdf.FromLatex as Pdf
import System.Directory (doesDirectoryExist)

import Dscp.Config
import Dscp.DB.SQL (SQL)
import Dscp.Educator.Config
import Dscp.Educator.DB.Resource ()
import Dscp.Educator.Launcher.Marker (EducatorNode)
import Dscp.Resource.AppDir
import Dscp.Resource.Class (AllocResource (..), buildComponentR)
import Dscp.Resource.Keys (KeyResources (..), linkStore)
import Dscp.Resource.Network (NetServResources)
import Dscp.Util.Exceptions
import Dscp.Util.HasLens
import qualified Dscp.Witness.Launcher.Resource as Witness
import System.FilePath.Posix (isRelative, (</>))

-- | Datatype which contains resources required by all Disciplina nodes
-- to start working.
data EducatorResources = EducatorResources
    { _erWitnessResources :: !Witness.WitnessResources
    , _erDB               :: !SQL
    , _erKeys             :: !(KeyResources EducatorNode)
    , _erPdfResourcePath  :: !Pdf.ResourcePath
    }

makeLenses ''EducatorResources
deriveHasLensDirect ''EducatorResources

deriveHasLens 'erWitnessResources ''EducatorResources ''Witness.WitnessResources
deriveHasLens 'erWitnessResources ''EducatorResources ''NetServResources

instance AllocResource (KeyResources EducatorNode) where
    type Deps (KeyResources EducatorNode) = (EducatorConfigRec, AppDir)
    allocResource (educatorCfg, appDir) =
        let baseParams = educatorCfg ^. sub #educator . sub #keys . sub #keyParams
        in buildComponentR "educator keys"
           (withCoreConfig (rcast educatorCfg) $
               linkStore baseParams appDir)
           (const pass)

instance AllocResource Pdf.ResourcePath where
    type Deps Pdf.ResourcePath = (FilePath, AppDir)
    allocResource (userPath, appDir) =
        buildComponentR "resources path" preparePath (\_ -> pass)
      where
        resPath
            | isRelative userPath = appDir </> userPath
            | otherwise = userPath
        preparePath = do
            logDebug $ "Certificate PDF resources path will be " +| resPath |+ ""
            unlessM (liftIO $ doesDirectoryExist resPath) $
                throwM $ DirectoryDoesNotExist "pdf templates" resPath
            -- TODO: maybe let's also check that "xelatex" can be found?
            return $ Pdf.ResourcePath resPath

instance AllocResource EducatorResources where
    type Deps EducatorResources = EducatorConfigRec
    allocResource educatorCfg = do
        let cfg = educatorCfg ^. sub #educator
            witnessCfg = rcast educatorCfg
        _erWitnessResources <- withWitnessConfig witnessCfg $
                               allocResource witnessCfg
        _erDB <- allocResource $ cfg ^. sub #db
        let appDir = Witness._wrAppDir _erWitnessResources
        _erKeys <- allocResource (educatorCfg, appDir)
        _erPdfResourcePath <- allocResource ( cfg ^. sub #certificates . option #resources
                                            , appDir )
        return EducatorResources {..}
