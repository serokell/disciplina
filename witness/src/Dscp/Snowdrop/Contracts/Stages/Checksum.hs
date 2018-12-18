
module Dscp.Snowdrop.Contracts.Stages.Checksum where

import Dscp.Crypto as Crypto
import Dscp.Snowdrop.Contracts.Contract
import Dscp.Snowdrop.Contracts.PublicationSignature
import Dscp.Snowdrop.Contracts.Entities
import Dscp.Snowdrop.Contracts.Util

data ContractChecksumTxId = ContractChecksumTxId
    deriving (Eq, Ord, Show, Generic)

data ContractChecksum = ContractChecksum
    { _ccContractID :: ContractID
    , _ccChecksum   :: PublicationSignature
    , _ccStage      :: Stage
    }
    deriving (Eq, Show, Generic)

instance Serialise ContractChecksumTxId
instance Serialise ContractChecksum

type ContractChecksumWitness = PersonalisedProof ContractChecksumTxId ContractChecksum

makeLenses ''ContractChecksum

checkBuyerCalculatedChecksum
    ::  ( HasPrism Proofs ContractChecksumWitness
        , HasPrism Proofs ContractChecksumTxId
        , HasGetter Crypto.PublicKey Address
        )
    =>  PreValidator Exceptions Ids Proofs Values ctx
checkBuyerCalculatedChecksum =
    PreValidator $ \StateTx { txProof } -> do
        Authenticated buyer _ ContractChecksum
            { _ccContractID = cid
            , _ccChecksum   = signature
            , _ccStage      = stage
            } _txFees
            <- authenticate @ContractChecksumTxId txProof

        contract     <- accessContractAsBuyerAtStage buyer cid Started
        theSignature <- getSignatureOfPublication (contract^.caPublication)

        () <- check (signature /= theSignature && stage == Transmitted)
            (NotCancellingOnIncorrectSig cid)

        return ()

expandChecksum
    ::  ( HasPrism Proofs ContractChecksumWitness
        , HasPrism Proofs ContractChecksumTxId
        , HasGetter Crypto.PublicKey Address
        )
    => AccountId
    -> Expand ctx ContractChecksumWitness
expandChecksum _miner =
    SeqExpanders $ one $ Expander
        (error "TODO: add read prefices")
        (error "TODO: add write prefices")
        $ \txProof -> do
            Authenticated _buyer _ ContractChecksum
                { _ccContractID = cid
                } _fees
                    <- authenticate @ContractChecksumTxId (inj txProof)

            setStage cid Transmitted

