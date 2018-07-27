-- | All educator's configurations.

module Dscp.Educator.Config
    ( EducatorConfig
    , EducatorConfigRec
    , HasEducatorConfig
    , withEducatorConfig
    , fillEducatorConfig

    , module Dscp.Witness.Config
    ) where

import Data.Reflection (Given)
import Loot.Config (ConfigKind (Final, Partial), ConfigRec)

import Dscp.Witness.Config


type EducatorConfig = CoreConfig

type EducatorConfigRecP = ConfigRec 'Partial EducatorConfig
type EducatorConfigRec = ConfigRec 'Final EducatorConfig

type HasEducatorConfig = Given EducatorConfigRec

withEducatorConfig :: EducatorConfigRec -> (HasEducatorConfig => a) -> a
withEducatorConfig = withCoreConfig

fillEducatorConfig :: EducatorConfigRecP -> IO EducatorConfigRecP
fillEducatorConfig = fillCoreConfig
