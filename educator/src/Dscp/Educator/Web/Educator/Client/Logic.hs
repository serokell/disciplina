module Dscp.Educator.Web.Educator.Client.Logic
       ( EducatorApiClientError
       , EducatorApiClient
       , hoistEducatorApiClient
       , createEducatorApiClient
       ) where

import Servant.Client (ClientM, client, runClientM)
import Servant.Generic (fromServant)
import Servant.Util ()

import Dscp.Educator.Web.Educator.API
import Dscp.Educator.Web.Educator.Error
import Dscp.Util
import Dscp.Web

-- | Exceptions which can appear from the client.
type EducatorApiClientError = ClientError EducatorAPIError

type EducatorApiClientM m = EducatorApiEndpoints (AsClientT m)
type EducatorApiClient = EducatorApiClientM IO

-- | Hoists existing @'EducatorApiClient'@ to another monad.
-- TODO: use `hoistClient` after migration to servant-0.15
hoistEducatorApiClient
    :: forall n m.
       (forall a. m a -> n a)
    -> EducatorApiEndpoints (AsClientT m)
    -> EducatorApiEndpoints (AsClientT n)
hoistEducatorApiClient nat es = EducatorApiEndpoints
    { eGetStatus               = nat ... eGetStatus es
    , eGetStudents             = nat ... eGetStudents es
    , eAddStudent              = nat ... eAddStudent es
    , eDeleteStudent           = nat ... eDeleteStudent es
    , eAddStudentCourse        = nat ... eAddStudentCourse es
    , eAddStudentAssignment    = nat ... eAddStudentAssignment es
    , eDeleteStudentAssignment = nat ... eDeleteStudentAssignment es
    , eGetCourses              = nat ... eGetCourses es
    , eAddCourse               = nat ... eAddCourse es
    , eGetCourse               = nat ... eGetCourse es
    , eGetAssignments          = nat ... eGetAssignments es
    , eAddAssignment           = nat ... eAddAssignment es
    , eGetSubmissions          = nat ... eGetSubmissions es
    , eGetSubmission           = nat ... eGetSubmission es
    , eDeleteSubmission        = nat ... eDeleteSubmission es
    , eGetGrades               = nat ... eGetGrades es
    , eAddGrade                = nat ... eAddGrade es
    , eGetProofs               = nat ... eGetProofs es
    , eGetCertificates         = nat ... eGetCertificates es
    , eGetCertificate          = nat ... eGetCertificate es
    , eAddCertificate          = nat ... eAddCertificate es
    }

-- | Creates a new @'EducatorApiClient'@ connecting to a given @'BaseUrl'@
createEducatorApiClient :: MonadIO m => BaseUrl -> m EducatorApiClient
createEducatorApiClient netAddr = do
    cliEnv <- buildClientEnv netAddr
    let nat :: ClientM a -> IO a
        nat act = runClientM act cliEnv
              >>= leftToThrow (servantToClientError @EducatorAPIError)

    let es :: EducatorApiEndpoints (AsClientT ClientM)
        es = fromServant $ client rawEducatorAPI
    return $ hoistEducatorApiClient nat es
