{-# LANGUAGE QuasiQuotes #-}

module Test.Dscp.Educator.Certificates where

import Data.Default (def)
import qualified Pdf.FromLatex as Pdf
import Servant.Util (fullContent)

import Dscp.DB.SQL
import Dscp.Educator
import Dscp.Educator.Web.Educator
import Dscp.Util.Test
import Dscp.Witness.Web

import Test.Dscp.DB.SQL.Mode
import Test.Dscp.Educator.Mode

spec_Educator_certificates :: Spec
spec_Educator_certificates = specWithTempPostgresServer $ do
    divideMaxSuccessBy 10 $ do
        -- each PDF production takes 2 sec, so running less
        it "Can build a full student certificate flawlessly" $ \_ -> property $
            \lang issuer cert faircv -> ioProperty $ do
                rawPdf <- Pdf.produce lang issuer cert testResourcePath
                pdf <- embedFairCVToCert faircv rawPdf
                return $ total pdf

        describe "Certificate endpoints" $ do
            it "Can add a certificate" $ educatorPropertyM $ do
                cert <- pickSmall arbitrary
                lift $ educatorAddCertificate cert

            it "Added certificate is verifiable" $ educatorPropertyM $ do
                cert <- pickSmall arbitrary

                lift $ do
                    educatorAddCertificate cert

                    [cId -> certId] <- invoke $ educatorGetCertificates def def
                    pdf <- invoke $ educatorGetCertificate certId
                    checkRes <- checkFairCVPDF pdf
                    return $ counterexample "FairCV is not verified" $
                             fairCVFullyValid $ fcacrCheckResult checkRes

            it "Sorting on certificates works" $ educatorPropertyM $ do
                n <- pick $ choose (0, 5)
                certs <- pickSmall $ replicateM n arbitrary
                sorting <- pick arbitrary

                lift $ do
                    forM_ certs educatorAddCertificate
                    void . invoke $ educatorGetCertificates sorting fullContent
