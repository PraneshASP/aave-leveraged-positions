// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ALP} from "./ALP.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console} from "forge-std/console.sol";

contract ALPFactory {
    using SafeERC20 for IERC20;

    mapping(address => address[]) private userALPs;
    mapping(address => address) public alpToOwner;

    struct CollateralInput {
        address asset;
        uint256 amount;
    }

    event ALPCreated(address indexed owner, address alpAddress);

    function createALP(CollateralInput[] calldata _collateralInputs, address _debtAsset, uint256 _leverageFactor)
        external
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, block.timestamp));

        address alpAddress = Create2.computeAddress(
            salt,
            keccak256(
                abi.encodePacked(
                    type(ALP).creationCode, abi.encode(msg.sender, _collateralInputs, _debtAsset, _leverageFactor)
                )
            ),
            address(this)
        );
        for (uint256 i = 0; i < _collateralInputs.length; i++) {
            IERC20(_collateralInputs[i].asset).safeTransferFrom(msg.sender, address(this), _collateralInputs[i].amount);
            IERC20(_collateralInputs[i].asset).safeIncreaseAllowance(alpAddress, _collateralInputs[i].amount);
        }

        address alp = Create2.deploy(
            0,
            salt,
            abi.encodePacked(
                type(ALP).creationCode, abi.encode(msg.sender, _collateralInputs, _debtAsset, _leverageFactor)
            )
        );

        userALPs[msg.sender].push(alp);
        alpToOwner[alp] = msg.sender;

        emit ALPCreated(msg.sender, alp);
        return alp;
    }

    function getALPOwner(address _alp) external view returns (address) {
        return alpToOwner[_alp];
    }

    function getUserALPs(address _user) external view returns (address[] memory) {
        return userALPs[_user];
    }

    function getALPLoanDetails(address _alp)
        external
        view
        returns (
            address owner,
            address[] memory collateralAssets,
            uint256[] memory collateralAmounts,
            address debtAsset,
            uint256 debtAmount
        )
    {
        return ALP(_alp).getPosition();
    }
}
