// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBitcoinSPV} from "./interfaces/IBitcoinSPV.sol";
import {Converter} from "./libraries/Converter.sol";
import {BitvmPolicy} from "./libraries/BitvmPolicy.sol";
import {BitvmTxParser} from "./libraries/BitvmTxParser.sol";

contract GatewayUpgradeable {
    enum PeginStatus {
        None,
        Processing,
        Withdrawbale,
        Locked,
        Claimed
    }
    enum WithdrawStatus {
        None,
        Processing,
        Initialized,
        Canceled,
        Complete,
        Disproved
    }

    struct PeginData {
        bytes32 peginTxid;
        PeginStatus status;
        uint64 peginAmount;
    }

    struct WithdrawData {
        bytes32 peginTxid;
        address operatorAddress;
        WithdrawStatus status;
        bytes16 instanceId;
        uint256 lockAmount;
    }

    struct OperatorData {
        uint64 stakeAmount;
        bytes1 operatorPubkeyPrefix;
        bytes32 operatorPubkey;
        bytes32 peginTxid;
        bytes32 preKickoffTxid;
        bytes32 kickoffTxid;
        bytes32 take1Txid;
        bytes32 assertInitTxid;
        bytes32[4] assertCommitTxids;
        bytes32 assertFinalTxid;
        bytes32 take2Txid;
    }

    IERC20 public immutable pegBTC;
    IBitcoinSPV public immutable bitcoinSPV;
    address public immutable relayer;

    mapping(bytes32 => bool) public peginTxUsed;
    mapping(bytes16 instanceId => PeginData) public peginDataMap;

    mapping(bytes16 graphId => bool) public operatorWithdrawn;
    mapping(bytes16 graphId => OperatorData) public operatorDataMap;
    mapping(bytes16 graphId => WithdrawData) public withdrawDataMap;

    bytes16[] public instanceIds;
    mapping(bytes16 instanceId => bytes16[] graphIds)
        public instanceIdToGraphIds;

    constructor(IERC20 _pegBTC, IBitcoinSPV _bitcoinSPV, address _relayer) {
        pegBTC = _pegBTC;
        bitcoinSPV = _bitcoinSPV;
        relayer = _relayer;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "not relayer!");
        _;
    }

    modifier onlyOperator(bytes16 graphId) {
        require(
            withdrawDataMap[graphId].operatorAddress == msg.sender,
            "not operator!"
        );
        _;
    }

    modifier onlyRelayerOrOperator(bytes16 graphId) {
        require(
            msg.sender == relayer ||
                withdrawDataMap[graphId].operatorAddress == msg.sender,
            "not relayer or operator!"
        );
        _;
    }

    function getInstanceIdsByPubKey(
        bytes32 operatorPubkey
    )
        external
        view
        returns (bytes16[] memory retInstanceIds, bytes16[] memory retGraphIds)
    {
        uint256 count;
        // First pass to count matching entries
        for (uint256 i = 0; i < instanceIds.length; ++i) {
            bytes16 instanceId = instanceIds[i];
            bytes16[] memory graphIds = instanceIdToGraphIds[instanceId];
            for (uint256 j = 0; j < graphIds.length; ++j) {
                bytes16 graphId = graphIds[j];
                if (
                    operatorDataMap[graphId].operatorPubkey == operatorPubkey &&
                    withdrawDataMap[graphId].status ==
                    WithdrawStatus.Initialized
                ) {
                    count++;
                }
            }
        }

        // Second pass to populate return arrays
        retInstanceIds = new bytes16[](count);
        retGraphIds = new bytes16[](count);
        uint256 index;
        for (uint256 i = 0; i < instanceIds.length; ++i) {
            bytes16 instanceId = instanceIds[i];
            bytes16[] memory graphIds = instanceIdToGraphIds[instanceId];
            for (uint256 j = 0; j < graphIds.length; ++j) {
                bytes16 graphId = graphIds[j];
                if (
                    operatorDataMap[graphId].operatorPubkey == operatorPubkey &&
                    withdrawDataMap[graphId].status ==
                    WithdrawStatus.Initialized
                ) {
                    retInstanceIds[index] = instanceId;
                    retGraphIds[index] = graphId;
                    index++;
                }
            }
        }
    }

    function getWithdrawableInstances()
        external
        view
        returns (
            bytes16[] memory retInstanceIds,
            bytes16[] memory retGraphIds,
            uint64[] memory retPeginAmounts
        )
    {
        uint256 count;

        // First pass to count
        for (uint256 i = 0; i < instanceIds.length; ++i) {
            bytes16 instanceId = instanceIds[i];
            bytes16[] memory graphIds = instanceIdToGraphIds[instanceId];
            for (uint256 j = 0; j < graphIds.length; ++j) {
                bytes16 graphId = graphIds[j];
                WithdrawData storage withdrawData = withdrawDataMap[graphId];
                PeginData storage peginData = peginDataMap[instanceId];
                if (
                    (withdrawData.status == WithdrawStatus.None ||
                        withdrawData.status == WithdrawStatus.Canceled) &&
                    peginData.status == PeginStatus.Withdrawbale &&
                    !operatorWithdrawn[graphId]
                ) {
                    count++;
                }
            }
        }

        // Second pass to collect
        retInstanceIds = new bytes16[](count);
        retGraphIds = new bytes16[](count);
        retPeginAmounts = new uint64[](count);
        uint256 index;

        for (uint256 i = 0; i < instanceIds.length; ++i) {
            bytes16 instanceId = instanceIds[i];
            bytes16[] memory graphIds = instanceIdToGraphIds[instanceId];
            for (uint256 j = 0; j < graphIds.length; ++j) {
                bytes16 graphId = graphIds[j];
                WithdrawData storage withdrawData = withdrawDataMap[graphId];
                PeginData storage peginData = peginDataMap[instanceId];
                if (
                    (withdrawData.status == WithdrawStatus.None ||
                        withdrawData.status == WithdrawStatus.Canceled) &&
                    peginData.status == PeginStatus.Withdrawbale &&
                    !operatorWithdrawn[graphId]
                ) {
                    retInstanceIds[index] = instanceId;
                    retGraphIds[index] = graphId;
                    retPeginAmounts[index] = peginData.peginAmount;
                    index++;
                }
            }
        }
    }

    function postPeginData(
        bytes16 instanceId,
        BitvmTxParser.BitcoinTx calldata rawPeginTx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayer {
        (
            bytes32 peginTxid,
            uint64 peginAmountSats,
            address depositorAddress
        ) = BitvmTxParser.parsePegin(rawPeginTx);

        require(
            peginDataMap[instanceId].peginTxid == 0,
            "pegin tx already posted"
        );
        // double spend check
        require(
            !peginTxUsed[peginTxid],
            "this pegin tx has already been posted"
        );

        // validate pegin tx
        require(
            verifyMerkleProof(
                bitcoinSPV.blockHash(height),
                proof,
                peginTxid,
                index
            ),
            "unable to verify"
        );

        // record pegin tx data
        peginTxUsed[peginTxid] = true;
        peginDataMap[instanceId] = PeginData({
            peginTxid: peginTxid,
            peginAmount: peginAmountSats,
            status: PeginStatus.Withdrawbale
        });
        instanceIds.push(instanceId);

        // mint / send pegBTC to user
        pegBTC.transfer(depositorAddress, peginAmountSats);
    }

    function postOperatorData(
        bytes16 instanceId,
        bytes16 graphId,
        OperatorData calldata operatorData
    ) public onlyRelayer {
        PeginData storage peginData = peginDataMap[instanceId];
        require(
            operatorData.peginTxid == peginData.peginTxid,
            "operator data pegin txid mismatch"
        );
        require(
            BitvmPolicy.isValidStakeAmount(operatorData.stakeAmount),
            "insufficient stake amount"
        );
        operatorDataMap[graphId] = operatorData;
    }

    function postOperatorDataBatch(
        bytes16 instanceId,
        bytes16[] calldata graphIds,
        OperatorData[] calldata operatorData
    ) external onlyRelayer {
        require(
            graphIds.length == operatorData.length,
            "inputs length mismatch"
        );
        for (uint256 i; i < graphIds.length; ++i) {
            postOperatorData(instanceId, graphIds[i], operatorData[i]);
        }
    }

    function initWithdraw(bytes16 instanceId, bytes16 graphId) external {
        WithdrawData storage withdrawData = withdrawDataMap[graphId];
        require(
            withdrawData.status == WithdrawStatus.None ||
                withdrawData.status == WithdrawStatus.Canceled,
            "invalid withdraw status"
        );
        PeginData storage peginData = peginDataMap[instanceId];
        require(
            peginData.status == PeginStatus.Withdrawbale,
            "not a withdrawable pegin tx"
        );
        require(
            !operatorWithdrawn[graphId],
            "operator already used up withdraw chance"
        );

        // lock the pegin utxo so others can not withdraw it
        peginData.status = PeginStatus.Locked;

        // lock operator's pegBTC
        uint256 lockAmount = Converter.amountFromSats(peginData.peginAmount);
        pegBTC.transferFrom(msg.sender, address(this), lockAmount);

        withdrawData.peginTxid = peginData.peginTxid;
        withdrawData.operatorAddress = msg.sender;
        withdrawData.status = WithdrawStatus.Initialized;
        withdrawData.instanceId = instanceId;
        withdrawData.lockAmount = lockAmount;

        instanceIdToGraphIds[instanceId].push(graphId);
    }

    function cancelWithdraw(
        bytes16 graphId
    ) external onlyRelayerOrOperator(graphId) {
        WithdrawData storage withdrawData = withdrawDataMap[graphId];
        PeginData storage peginData = peginDataMap[withdrawData.instanceId];
        require(
            withdrawData.status == WithdrawStatus.Initialized,
            "invalid withdraw index: not at init stage"
        );
        withdrawData.status = WithdrawStatus.Canceled;
        pegBTC.transfer(msg.sender, withdrawData.lockAmount);
        peginData.status = PeginStatus.Withdrawbale;
    }

    // post kickoff tx
    function proceedWithdraw(
        bytes16 graphId,
        BitvmTxParser.BitcoinTx calldata rawKickoffTx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayerOrOperator(graphId) {
        WithdrawData storage withdrawData = withdrawDataMap[graphId];
        bytes16 instanceId = withdrawData.instanceId;
        PeginData storage peginData = peginDataMap[instanceId];
        require(
            withdrawData.status == WithdrawStatus.Initialized,
            "invalid withdraw index: not at init stage"
        );

        OperatorData storage operatorData = operatorDataMap[graphId];
        bytes32 kickoffTxid = BitvmTxParser.parseKickoffTx(rawKickoffTx);
        require(
            kickoffTxid == operatorData.kickoffTxid,
            "kickoff txid mismatch"
        );
        require(
            verifyMerkleProof(
                bitcoinSPV.blockHash(height),
                proof,
                kickoffTxid,
                index
            ),
            "unable to verify"
        );

        // once kickoff is braodcasted , operator will not be able to cancel withdrawal
        withdrawData.status = WithdrawStatus.Processing;
        operatorWithdrawn[graphId] = true;

        // TODO: burn pegBTC ?
    }

    function finishWithdrawHappyPath(
        bytes16 graphId,
        BitvmTxParser.BitcoinTx calldata rawTake1Tx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayerOrOperator(graphId) {
        WithdrawData storage withdrawData = withdrawDataMap[graphId];
        bytes16 instanceId = withdrawData.instanceId;
        PeginData storage peginData = peginDataMap[instanceId];
        require(
            withdrawData.status == WithdrawStatus.Processing,
            "invalid withdraw index: not at processing stage"
        );

        OperatorData storage operatorData = operatorDataMap[graphId];
        bytes32 take1Txid = BitvmTxParser.parseTake1Tx(rawTake1Tx);
        require(
            BitvmTxParser.parseTake1Tx(rawTake1Tx) == operatorData.take1Txid,
            "take1 txid mismatch"
        );
        require(
            verifyMerkleProof(
                bitcoinSPV.blockHash(height),
                proof,
                take1Txid,
                index
            ),
            "unable to verify"
        );

        peginData.status = PeginStatus.Claimed;
        withdrawData.status = WithdrawStatus.Complete;
    }

    function finishWithdrawUnhappyPath(
        bytes16 graphId,
        BitvmTxParser.BitcoinTx calldata rawTake2Tx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayerOrOperator(graphId) {
        WithdrawData storage withdrawData = withdrawDataMap[graphId];
        bytes16 instanceId = withdrawData.instanceId;
        PeginData storage peginData = peginDataMap[instanceId];
        require(
            withdrawData.status == WithdrawStatus.Processing,
            "invalid withdraw index: not at processing stage"
        );

        OperatorData storage operatorData = operatorDataMap[graphId];
        bytes32 take2Txid = BitvmTxParser.parseTake2Tx(rawTake2Tx);
        require(take2Txid == operatorData.take2Txid, "take2 txid mismatch");
        require(
            verifyMerkleProof(
                bitcoinSPV.blockHash(height),
                proof,
                take2Txid,
                index
            ),
            "unable to verify"
        );

        peginData.status = PeginStatus.Claimed;
        withdrawData.status = WithdrawStatus.Complete;
    }

    function finishWithdrawDisproved(
        bytes16 graphId,
        BitvmTxParser.BitcoinTx calldata rawDisproveTx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayerOrOperator(graphId) {
        WithdrawData storage withdrawData = withdrawDataMap[graphId];
        bytes16 instanceId = withdrawData.instanceId;
        PeginData storage peginData = peginDataMap[instanceId];
        require(
            withdrawData.status == WithdrawStatus.Processing,
            "invalid withdraw index: not at processing stage"
        );

        OperatorData storage operatorData = operatorDataMap[graphId];
        (bytes32 disproveTxid, bytes32 assertFinalTxid) = BitvmTxParser
            .parseDisproveTx(rawDisproveTx);
        require(
            assertFinalTxid == operatorData.assertFinalTxid,
            "disprove txid mismatch"
        );
        require(
            verifyMerkleProof(
                bitcoinSPV.blockHash(height),
                proof,
                assertFinalTxid,
                index
            ),
            "unable to verify"
        );

        peginData.status = PeginStatus.Withdrawbale;
        withdrawData.status = WithdrawStatus.Disproved;
    }

    function verifyMerkleProof(
        bytes32 root,
        bytes32[] memory proof,
        bytes32 leaf,
        uint256 index
    ) public pure returns (bool) {
        bytes32 computedHash = leaf;

        for (uint256 i; i < proof.length; ++i) {
            if (index % 2 == 0) {
                computedHash = _doubleSha256Pair(computedHash, proof[i]);
            } else {
                computedHash = _doubleSha256Pair(proof[i], computedHash);
            }
            index /= 2;
        }

        return computedHash == root;
    }

    function _doubleSha256Pair(
        bytes32 txA,
        bytes32 txB
    ) internal pure returns (bytes32) {
        // concatenate and do sha256 once
        bytes32 hash = sha256(abi.encodePacked(txA, txB));

        // do sha256 once again
        return sha256(abi.encodePacked(hash));
    }

    /*
        How to check whether operator has burned pegBTC ?
        Inputs:
            1. graphId (provided by operator when kickoff)
            2. gateway_contract_address (hardcoded when pegin)
            3. withdrawMap_layout_index (hardcoded when pegin)
            4. evm_header.status_root (already been proven somewhere else)
            5. account_proof & storage_proofs (see https://web3js.readthedocs.io/en/v1.10.0/web3-eth.html#getproof)
        Verification:
            1. let leaf_account = verify_account_merkle_proof(
                    evm_header.status_root, 
                    account_proof, 
                    gateway_contract_address // i.e. account_key
                ); 
            2. let storage_keys = calc_storage_key(     // TODO
                    withdrawMap_layout_index,
                    graphId,
                    [1, 2, 3] 
                ); (see https://docs.soliditylang.org/en/v0.8.29/internals/layout_in_storage.html#mappings-and-dynamic-arrays)
            3. let leaf_storage_slots = verify_storage_merkle_proof(
                    leaf_account.storage_root,
                    storage_proofs,
                    storage_keys,
                )
            4. leaf_storage_slots[0] == pegin_txid // pegin_txid is hardcoded
            5. leaf_storage_slots[1] == operator_address // operator_address is hardcoded
            6. leaf_storage_slots[2] == WithdrawStatus.Processing
    */
}
