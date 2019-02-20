{-# LANGUAGE GADTs #-}

-- | Resources used by Educator node

module Dscp.MultiEducator.Launcher.Resource
       ( EducatorContexts (..)
       , EducatorCtxWithCfg (..)
       , MultiEducatorResources (..)
       , merWitnessResources
       ) where

import Control.Lens (makeLenses)
import qualified Pdf.FromLatex as Pdf

import Dscp.Config
import Dscp.DB.SQL (SQL)
import qualified Dscp.Educator.Config as E
import qualified Dscp.Educator.Launcher.Mode as E
import Dscp.MultiEducator.Config
import Dscp.Resource.Class (AllocResource (..))
import Dscp.Resource.Network (NetServResources)
import Dscp.Util.HasLens
import qualified Dscp.Witness.Launcher.Resource as Witness

data EducatorCtxWithCfg where
    EducatorCtxWithCfg :: E.HasEducatorConfig => E.EducatorContext -> EducatorCtxWithCfg
newtype EducatorContexts = EducatorContexts (Map Text EducatorCtxWithCfg)

-- | Datatype which contains resources required by all Disciplina nodes
-- to start working.
data MultiEducatorResources = MultiEducatorResources
    { _merWitnessResources :: !Witness.WitnessResources
    , _merDB               :: !SQL
    , _merEducatorData     :: !(TVar EducatorContexts)
    , _merPdfLatexPath     :: !Pdf.LatexPath
    , _merPdfResourcePath  :: !Pdf.ResourcePath
    }

makeLenses ''MultiEducatorResources
deriveHasLensDirect ''MultiEducatorResources

deriveHasLens 'merWitnessResources ''MultiEducatorResources ''Witness.WitnessResources
deriveHasLens 'merWitnessResources ''MultiEducatorResources ''NetServResources

instance AllocResource MultiEducatorResources where
    type Deps MultiEducatorResources = MultiEducatorConfigRec
    allocResource educatorCfg = do
        let cfg = educatorCfg ^. sub #educator
            witnessCfg = rcast educatorCfg
        _merWitnessResources <- withWitnessConfig witnessCfg $
                               allocResource witnessCfg
        _merDB <- allocResource $ cfg ^. sub #db
        _merEducatorData <- atomically $ newTVar (EducatorContexts mempty)
        let appDir = Witness._wrAppDir _merWitnessResources
        _merPdfLatexPath <- allocResource $ cfg ^. sub #certificates . option #latex
        _merPdfResourcePath <- allocResource
            (cfg ^. sub #certificates . option #resources, appDir)
        return MultiEducatorResources {..}
