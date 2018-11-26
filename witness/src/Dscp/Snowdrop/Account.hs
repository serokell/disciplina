
module Dscp.Snowdrop.Account where

import Codec.Serialise (Serialise)
import Control.Lens (makePrisms)
import Data.Default (Default (..))
import Data.Text.Buildable (Buildable (..))
import Fmt (build, (+|), (|+), (+||), (||+))
import qualified Text.Show

import Dscp.Core

-- | Type for possible failures during transaction validation.
data AccountException
    = MTxNoOutputs
    | MTxDuplicateOutputs
    | TransactionAlreadyExists
      { taeTxId :: TxId }
    | InsufficientFees
      { aeExpectedFees :: Integer, aeActualFees :: Integer }
    | SignatureIsMissing
    | SignatureIsCorrupted
    | TransactionIsCorrupted
    | NotASingletonSelfUpdate      -- ^ 'Author' account updated multiple times.
    | NonceMustBeIncremented
      { aePreviousNonce :: Nonce, aeNewNonce :: Nonce }
    | PaymentMustBePositive
    | ReceiverOnlyGetsMoney        -- ^ Receiver can only change its 'aBalance', never 'aNonce'.
    | ReceiverMustIncreaseBalance  -- ^ Receiver cannot decrease in its 'aBalance'.
    | SumMustBeNonNegative
      { aeSent :: Integer, aeReceived :: Integer, aeFees :: Integer }
      -- ^ Amount of money sent must be greater of equal
      -- to the total amount received.
    | CannotAffordFees
      { aeOutputsSum :: Integer, aeBalance :: Integer, aeFees :: Integer }
      -- ^ Given account state cannot afford given fees.
    | BalanceCannotBecomeNegative
      { aeSpent :: Integer, aeBalance :: Integer }
    | AccountInternalError String
    deriving (Eq, Ord)

instance Buildable AccountException where
    build = \case
        MTxNoOutputs ->
            "Transaction has no outputs"
        MTxDuplicateOutputs ->
            "Duplicated transaction outputs"
        TransactionAlreadyExists{..} ->
            "Transaction " +| taeTxId |+ " has already been registered"
        InsufficientFees{..} ->
            "Amount of money left for fees in transaction is not enough, \
             \expected " +| unsafeMkCoin aeExpectedFees |+ ", got " +| unsafeMkCoin aeActualFees |+ ""
        SignatureIsMissing ->
            "Transaction has no correct signature"
        SignatureIsCorrupted ->
            "Bad signature"
        TransactionIsCorrupted ->
            "Transaction is corrupted"
        NotASingletonSelfUpdate ->
            "Author account is updated multiple times"
        NonceMustBeIncremented{..} ->
            "Nonce should've been incremented by one: previous nonce was "
            +| aePreviousNonce |+ ", new nonce is " +| aeNewNonce |+ ""
        PaymentMustBePositive ->
            "Spent amount of money must be positive"
        ReceiverOnlyGetsMoney ->
            "Improper changes of receiver account (it is only possible to add \
            \tokens)"
        ReceiverMustIncreaseBalance ->
            "One of receivers' balance decreased or didn't change"
        SumMustBeNonNegative{..} ->
            "Tx input value (" +| unsafeMkCoin aeSent |+ ") is not greater than \
            \sum of outputs (" +| unsafeMkCoin aeReceived |+ ") plus fees (" +| unsafeMkCoin aeFees |+ ")"
        CannotAffordFees{..} ->
            "Tx sender can not afford fees: sending " +| unsafeMkCoin aeOutputsSum |+ " \
            \and fees are " +| unsafeMkCoin aeFees |+ ", while balance is " +| unsafeMkCoin aeBalance |+ ""
        BalanceCannotBecomeNegative{..} ->
            "Balance can not become negative: spending " +| unsafeMkCoin aeSpent |+ ", \
            \while balance is " +| unsafeMkCoin aeBalance |+ ""
        AccountInternalError s ->
            fromString $ "Expander failed internally: " <> s
        AccountDoesNotExist acc ->
            "Account " +|| acc ||+ " does not exist"

instance Show AccountException where
    show = toString . pretty

-- | Transaction type for block metas.
data BlockMetaTxTypeId = BlockMetaTxTypeId deriving (Eq, Ord, Show, Generic)

data BlockException
    = DuplicatedDifficulty
      { bmeProvidedHeader :: Header, bmeExistingHeaderHash :: HeaderHash }
    | DifficultyIsTooLarge
      { bmeDifficulty :: Difficulty }
    | PrevBlockIsIncorrect
      { bmeProvidedHash :: HeaderHash, bmeTipHash :: HeaderHash }
    | SlotIdIsNotIncreased
      { bmeProvidedSlotId :: SlotId, bmeTipSlotId :: SlotId }
    | InvalidBlockSignature
    | IssuerDoesNotOwnSlot
      { bmrSlotId :: SlotId, bmrIssuer :: Address }
    | BlockApplicationError (BlockApplicationException HeaderHash)
    | BlockMetaInternalError Text

makePrisms ''BlockException

instance Buildable BlockException where
    build = \case
        DuplicatedDifficulty{..} ->
            "Block with this difficulty already exists: provided " +| bmeProvidedHeader |+
            ", but another block " +| bmeExistingHeaderHash |+ " already exists in chain."
        DifficultyIsTooLarge{..} ->
            "Difficulty should've been incremented by one, but is larger: "
            +| bmeDifficulty |+ ""
        PrevBlockIsIncorrect{..} ->
            "Previous block is incorrect: expected " +| bmeTipHash |+
            ", given " +| bmeProvidedHash |+ ""
        SlotIdIsNotIncreased{..} ->
            "Slot id should've been increased: provided " +| bmeProvidedSlotId |+
            ", current tip was created at " +| bmeTipSlotId |+ ""
        InvalidBlockSignature ->
            "Block signature is invalid"
        IssuerDoesNotOwnSlot{..} ->
            "Node " +| bmrIssuer |+ " does not own slot " +| bmrSlotId |+ ""
        BlockApplicationError err ->
            build err
        BlockMetaInternalError msg ->
            "Internal error: " +| msg |+ ""

instance HasReview BlockException (BlockApplicationException HeaderHash) where
    inj = BlockApplicationError


-- | Wrapper for address.
newtype AccountId = AccountId { unAccountId :: Address }
    deriving (Eq, Ord, Show, Generic)

-- | Slice of account that interest us while doing money transfers.
data Account = Account
    { aBalance :: Integer  -- ^ Account balance.
    , aNonce   :: Nonce    -- ^ Account nonce.
    } deriving (Eq, Ord, Show, Generic)

-- | How absense of account in db should look like outside.
instance Default Account where
    def = Account{ aBalance = 0, aNonce = 0 }

instance Buildable Account where
    build Account{..} = "account: bal " +| aBalance |+ ", nonce " +| aNonce |+ ""

instance Serialise Account
instance Serialise AccountId

makePrisms ''AccountException
