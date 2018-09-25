module Dscp.Educator.Launcher.Params
       ( EducatorKeyParams (..)
       ) where

import Data.Aeson (FromJSON (..))

import Dscp.Resource.Keys (BaseKeyParams)

-- | Educator key parameters.
newtype EducatorKeyParams = EducatorKeyParams
    { unEducatorKeyParams :: Maybe FilePath
    } deriving (Show, FromJSON)
