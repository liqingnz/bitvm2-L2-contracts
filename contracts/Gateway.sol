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
        uint64 operatorNum;
    }

    struct WithdrawData {
        bytes32 peginTxid;
        WithdrawStatus status;
        uint256 peginIndex;
        uint256 operatorIndex;
        uint256 lockAmount;
    }

    struct OperatorData {
        uint64 stakeAmount;
        address operatorAddress;
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

    uint256 public globalPeginIndex;
    uint256 public globalWithdrawIndex;
    mapping(bytes32 => bool) public peginTxUsed;
    mapping(uint256 => mapping(uint256 => bool)) public operatorWithdrawn;
    mapping(uint256 => PeginData) public peginDataMap; // start from index 1
    mapping(uint256 => mapping(uint256 => OperatorData)) public operatorDataMap;
    mapping(uint256 => WithdrawData) public withdrawDataMap;

    constructor(IERC20 _pegBTC, IBitcoinSPV _bitcoinSPV, address _relayer) {
        pegBTC = _pegBTC;
        bitcoinSPV = _bitcoinSPV;
        relayer = _relayer;
    }

    modifier onlyRelayer() {
        require(msg.sender == relayer, "not relayer!");
        _;
    }

    modifier onlyOperator(uint256 peginIndex, uint256 operatorIndex) {
        require(
            operatorDataMap[peginIndex][operatorIndex].operatorAddress ==
                msg.sender,
            "not operator!"
        );
        _;
    }

    modifier onlyRelayerOrOperator(uint256 withdrawIndex) {
        require(
            msg.sender == relayer ||
                operatorDataMap[withdrawDataMap[withdrawIndex].peginIndex][
                    withdrawDataMap[withdrawIndex].operatorIndex
                ].operatorAddress ==
                msg.sender,
            "not relayer or operator!"
        );
        _;
    }

    function postPeginData(
        BitvmTxParser.BitcoinTx calldata rawPeginTx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayer returns (uint256 peginIndex) {
        (
            bytes32 peginTxid,
            uint64 peginAmountSats,
            address depositorAddress
        ) = BitvmTxParser.parsePegin(rawPeginTx);

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
        peginDataMap[++globalPeginIndex] = PeginData({
            peginTxid: peginTxid,
            peginAmount: peginAmountSats,
            status: PeginStatus.Withdrawbale,
            operatorNum: 0
        });

        // mint / send pegBTC to user
        pegBTC.transfer(depositorAddress, peginAmountSats);

        return globalPeginIndex;
    }

    function postOperatorData(
        uint256 PeginIndex,
        OperatorData calldata operatorData
    ) public onlyRelayer returns (uint256 operatorIndex) {
        PeginData storage peginData = peginDataMap[PeginIndex];
        require(
            operatorData.peginTxid == peginData.peginTxid,
            "operator data pegin txid mismatch"
        );
        require(
            BitvmPolicy.isValidStakeAmount(operatorData.stakeAmount),
            "insufficient stake amount"
        );
        operatorIndex = peginData.operatorNum++;
        operatorDataMap[PeginIndex][operatorIndex] = operatorData;
    }

    function postOperatorDataBatch(
        uint256 PeginIndex,
        OperatorData[] calldata operatorData
    ) external onlyRelayer returns (uint[] memory operatorIndex) {
        for (uint256 i; i < operatorData.length; ++i) {
            operatorIndex[i] = postOperatorData(PeginIndex, operatorData[i]);
        }
    }

    function initWithdraw(
        uint256 peginIndex,
        uint256 operatorIndex
    )
        external
        onlyOperator(peginIndex, operatorIndex)
        returns (uint256 withdrawIndex)
    {
        PeginData storage peginData = peginDataMap[peginIndex];

        require(
            peginData.status == PeginStatus.Withdrawbale,
            "not a withdrawable pegin tx"
        );
        require(
            !operatorWithdrawn[peginIndex][operatorIndex],
            "operator already used up withdraw chance"
        );

        // lock the pegin utxo so others can not withdraw it
        peginData.status = PeginStatus.Locked;

        // lock operator's pegBTC
        uint256 lockAmount = Converter.amountFromSats(peginData.peginAmount);
        pegBTC.transferFrom(msg.sender, address(this), lockAmount);

        WithdrawData memory withdrawal = WithdrawData({
            peginTxid: peginData.peginTxid,
            status: WithdrawStatus.Initialized,
            operatorIndex: operatorIndex,
            peginIndex: peginIndex,
            lockAmount: lockAmount
        });
        withdrawDataMap[++globalWithdrawIndex] = withdrawal;
        return globalWithdrawIndex;
    }

    function cancelWithdraw(
        uint256 withdrawIndex
    ) external onlyRelayerOrOperator(withdrawIndex) {
        WithdrawData storage withdrawData = withdrawDataMap[withdrawIndex];
        PeginData storage peginData = peginDataMap[withdrawData.peginIndex];
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
        uint256 withdrawIndex,
        BitvmTxParser.BitcoinTx calldata rawKickoffTx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayerOrOperator(withdrawIndex) {
        WithdrawData storage withdrawData = withdrawDataMap[withdrawIndex];
        uint256 peginIndex = withdrawData.peginIndex;
        uint256 operatorIndex = withdrawData.operatorIndex;
        PeginData storage peginData = peginDataMap[peginIndex];
        require(
            operatorIndex < peginData.operatorNum,
            "operator index out of range"
        );
        require(
            withdrawData.status == WithdrawStatus.Initialized,
            "invalid withdraw index: not at init stage"
        );

        OperatorData storage operatorData = operatorDataMap[peginIndex][
            operatorIndex
        ];
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
        operatorWithdrawn[peginIndex][operatorIndex] = true;

        // TODO: burn pegBTC ?
    }

    function finishWithdrawHappyPath(
        uint256 withdrawIndex,
        BitvmTxParser.BitcoinTx calldata rawTake1Tx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayerOrOperator(withdrawIndex) {
        WithdrawData storage withdrawData = withdrawDataMap[withdrawIndex];
        uint256 peginIndex = withdrawData.peginIndex;
        uint256 operatorIndex = withdrawData.operatorIndex;
        PeginData storage peginData = peginDataMap[peginIndex];
        require(
            operatorIndex < peginData.operatorNum,
            "operator index out of range"
        );
        require(
            withdrawData.status == WithdrawStatus.Processing,
            "invalid withdraw index: not at processing stage"
        );

        OperatorData storage operatorData = operatorDataMap[peginIndex][
            operatorIndex
        ];
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
        uint256 withdrawIndex,
        BitvmTxParser.BitcoinTx calldata rawTake2Tx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayerOrOperator(withdrawIndex) {
        WithdrawData storage withdrawData = withdrawDataMap[withdrawIndex];
        uint256 peginIndex = withdrawData.peginIndex;
        uint256 operatorIndex = withdrawData.operatorIndex;
        PeginData storage peginData = peginDataMap[peginIndex];
        require(
            operatorIndex < peginData.operatorNum,
            "operator index out of range"
        );
        require(
            withdrawData.status == WithdrawStatus.Processing,
            "invalid withdraw index: not at processing stage"
        );

        OperatorData storage operatorData = operatorDataMap[peginIndex][
            operatorIndex
        ];
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
        uint256 withdrawIndex,
        BitvmTxParser.BitcoinTx calldata rawDisproveTx,
        uint256 height,
        bytes32[] calldata proof,
        uint256 index
    ) external onlyRelayerOrOperator(withdrawIndex) {
        WithdrawData storage withdrawData = withdrawDataMap[withdrawIndex];
        uint256 peginIndex = withdrawData.peginIndex;
        uint256 operatorIndex = withdrawData.operatorIndex;
        PeginData storage peginData = peginDataMap[peginIndex];
        require(
            operatorIndex < peginData.operatorNum,
            "operator index out of range"
        );
        require(
            withdrawData.status == WithdrawStatus.Processing,
            "invalid withdraw index: not at processing stage"
        );

        OperatorData storage operatorData = operatorDataMap[peginIndex][
            operatorIndex
        ];
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
            1. withdrawIndex (provided by operator when kickoff)
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
                    withdrawIndex,
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
