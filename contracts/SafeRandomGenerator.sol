pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

contract SafeRandomGenerator {
	function generateRandomHash() external view returns (bytes32) {
		return
			keccak256(abi.encodePacked(blockhash(block.number - 1), blockhash(block.number + 1), block.timestamp, block.difficulty, block.timestamp));
	}
}
