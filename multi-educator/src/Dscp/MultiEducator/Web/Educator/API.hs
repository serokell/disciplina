{-# LANGUAGE DataKinds     #-}
{-# LANGUAGE TypeOperators #-}

-- | Educator HTTP API definition.

module Dscp.MultiEducator.Web.Educator.API
    ( CertificatesApiEndpoints (..)
    , CertificatesApiHandlers
    , MultiEducatorAPI
    , multiEducatorAPI
    , MultiStudentAPI
    , multiStudentAPI
    ) where

import Servant
import Servant.Generic

import Dscp.Educator.Web.Auth
import Dscp.Educator.Web.Educator.API
import Dscp.Educator.Web.Student.API
import Dscp.MultiEducator.Web.Educator.Auth
import Dscp.MultiEducator.Web.Educator.Types
import Dscp.Witness.Web.ContentTypes

-- | Endpoints of public certificate API.
data CertificatesApiEndpoints route = CertificatesApiEndpoints
    { cGetCertificate :: route :- GetCertificatePublic
    } deriving (Generic)

type CertificatesAPI = ToServant (CertificatesApiEndpoints AsApi)
type CertificatesApiHandlers m = CertificatesApiEndpoints (AsServerT m)

type MultiEducatorAPI =
    "api" :> "educator" :> "v1" :> ProtectedMultiEducatorAPI
    :<|>
    "api" :> "certificates" :> "v1" :> CertificatesAPI

type ProtectedMultiEducatorAPI =
    Auth' '[MultiEducatorAuth, NoAuth "multi-educator"] EducatorAuthData :> RawEducatorAPI

type MultiStudentAPI = Capture "educator" Text :> ProtectedStudentAPI

-- | Endpoint for getting a certificate by full ID.
type GetCertificatePublic
    = "cert" :> Capture "certificate" CertificateName
    :> Summary "Get the certificate by ID"
    :> Description "Gets the PDF certificate with FairCV JSON included as metadata by ID. \
        \CertificateID is obtained as `base64url(\"<educator-UUID>:<certificate-hash>\")`, \
        \where `<educator-UUID>` is the UUID assigned by AAA microservice to Educator, \
        \and `<certificate-hash>` is a hash of certificate meta."
    :> Get '[PDF] PDFBody

multiEducatorAPI :: Proxy MultiEducatorAPI
multiEducatorAPI = Proxy

multiStudentAPI :: Proxy MultiStudentAPI
multiStudentAPI = Proxy
