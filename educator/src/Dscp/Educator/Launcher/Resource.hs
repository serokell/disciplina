{-# LANGUAGE OverloadedLabels #-}

-- | Resources used by Educator node

module Dscp.Educator.Launcher.Resource
       ( EducatorResources (..)
       , erWitnessResources
       ) where

import Control.Lens (makeLenses)
import Loot.Config (option, sub)

import Dscp.Config
import Dscp.DB.SQLite
import Dscp.Educator.Config
import Dscp.Educator.Launcher.Marker (EducatorNode)
import Dscp.Educator.Launcher.Params (EducatorKeyParams (..))
import Dscp.Resource.AppDir
import Dscp.Resource.Class (AllocResource (..), buildComponentR)
import Dscp.Resource.Keys (KeyResources (..), linkStore)
import Dscp.Resource.Network (NetServResources)
import Dscp.Resource.SQLite ()
import Dscp.Util.HasLens
import qualified Dscp.Witness.Launcher.Resource as Witness

-- SQL resource should be here too (in the future).
-- | Datatype which contains resources required by all Disciplina nodes
-- to start working.
data EducatorResources = EducatorResources
    { _erWitnessResources :: !Witness.WitnessResources
    , _erDB               :: !SQLiteDB  -- TODO [DSCP-405]: remove
    , _erDBBackend        :: !SomeSQLBackend
    , _erKeys             :: !(KeyResources EducatorNode)
    }

makeLenses ''EducatorResources
deriveHasLensDirect ''EducatorResources

deriveHasLens 'erWitnessResources ''EducatorResources ''Witness.WitnessResources
deriveHasLens 'erWitnessResources ''EducatorResources ''NetServResources

instance AllocResource (KeyResources EducatorNode) where
    type Deps (KeyResources EducatorNode) = (EducatorConfigRec, AppDir)
    allocResource (educatorCfg, appDir) =
        let EducatorKeyParams baseParams =
                educatorCfg ^. sub #educator . option #keys
        in buildComponentR "educator keys"
           (withCoreConfig (rcast educatorCfg) $
               linkStore baseParams appDir)
           (const pass)

instance AllocResource EducatorResources where
    type Deps EducatorResources = EducatorConfigRec
    allocResource educatorCfg = do
        let cfg = educatorCfg ^. sub #educator
            witnessCfg = rcast educatorCfg
        _erWitnessResources <- withWitnessConfig witnessCfg $
                               allocResource witnessCfg
        _erDB <- allocResource $ cfg ^. option #db
        let _erDBBackend = SomeSQLBackend SQLiteBackend
        let appDir = Witness._wrAppDir _erWitnessResources
        _erKeys <- allocResource (educatorCfg, appDir)
        return EducatorResources {..}
