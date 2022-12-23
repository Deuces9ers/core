// SPDX-FileCopyrightText: 2020 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.4.24;

import "../nos/NodeOperatorsRegistry.sol";

contract NodeOperatorsRegistryMock is NodeOperatorsRegistry {
    function setOperatorTotalKeys(uint256 _operatorId, uint64 _keys) external {
        operators[_operatorId].totalSigningKeys = _keys;
    }

    function setOperatorUsedKeys(uint256 _operatorId, uint64 _keys) external {
        operators[_operatorId].usedSigningKeys = _keys;
    }

    function setOperatorStoppedKeys(uint256 _operatorId, uint64 _keys) external {
        operators[_operatorId].stoppedValidators = _keys;
    }

    function setTotalKeys(uint256 _keys) external {
        signingKeysStats.totalSigningKeys = uint64(_keys);
    }

    function setTotalUsedKeys(uint256 _keys) external {
        signingKeysStats.usedSigningKeys = uint64(_keys);
    }

    function setTotalStoppedKeys(uint256 _keys) external {
        signingKeysStats.stoppedSigningKeys = uint64(_keys);
    }
}
