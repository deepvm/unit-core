// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract CumulativeMerkleDrop is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    bytes32 public merkleRoot;

    mapping(address => uint256) public cumulativeClaimed;

    event MerkleRootUpdated(bytes32 indexed newRoot);
    event Claimed(address indexed account, uint256 amount);

    constructor(IERC20 token_, bytes32 merkleRoot_) Ownable(msg.sender) {
        token = token_;
        merkleRoot = merkleRoot_;
    }

    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        merkleRoot = newRoot;
        emit MerkleRootUpdated(newRoot);
    }

    function claim(
        address account,
        uint256 cumulativeAmount,
        bytes32 expectedMerkleRoot,
        bytes32[] calldata merkleProof
    ) external {
        require(merkleRoot == expectedMerkleRoot, "Merkle root changed");

        bytes32 leaf = keccak256(abi.encodePacked(account, cumulativeAmount));
        require(MerkleProof.verify(merkleProof, merkleRoot, leaf), "Invalid proof");

        uint256 claimed = cumulativeClaimed[account];
        require(cumulativeAmount > claimed, "Nothing to claim");

        uint256 amountToClaim = cumulativeAmount - claimed;
        cumulativeClaimed[account] = cumulativeAmount;

        token.safeTransfer(account, amountToClaim);
        emit Claimed(account, amountToClaim);
    }
}
