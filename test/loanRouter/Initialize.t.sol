// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {RouterFixture} from "../helpers/RouterFixture.sol";

import {LoanRouterV2} from "src/LoanRouterV2.sol";
import {ILoanRouterV2} from "src/interfaces/ILoanRouterV2.sol";

contract LoanRouterV2InitializeTest is RouterFixture {
    /*------------------------------------------------------------------------*/
    /* Test: initialize - happy path */
    /*------------------------------------------------------------------------*/

    function test__Initialize_SetsFeeRecipient() public view {
        assertEq(router.feeRecipient(), users.feeRecipient);
    }

    function test__Initialize_GrantsAdminRole() public view {
        assertTrue(router.hasRole(bytes32(0), users.admin)); /* DEFAULT_ADMIN_ROLE */
    }

    function test__Initialize_SetsERC721NameAndSymbol() public view {
        assertEq(ERC721Upgradeable(address(router)).name(), "USDai Loan Router V2");
        assertEq(ERC721Upgradeable(address(router)).symbol(), "USDai-LR-V2");
    }

    function test__Initialize_DepositAndEscrowTimelockImmutables() public view {
        assertEq(router.depositTimelock(), address(depositTimelock));
        assertEq(router.escrowTimelock(), address(escrowTimelock));
    }

    /*------------------------------------------------------------------------*/
    /* Test: initialize - reverts */
    /*------------------------------------------------------------------------*/

    function test__Initialize_RevertWhen_AdminZero() public {
        LoanRouterV2 impl = new LoanRouterV2(
            users.feeRecipient, address(collateralTimelock), address(depositTimelock), address(escrowTimelock)
        );
        vm.expectRevert(ILoanRouterV2.InvalidAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeWithSelector(LoanRouterV2.initialize.selector, address(0)));
    }

    function test__Initialize_RevertWhen_AlreadyInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        router.initialize(users.admin);
    }

    function test__Initialize_RevertWhen_CalledOnImplementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        routerImpl.initialize(users.admin);
    }

    /*------------------------------------------------------------------------*/
    /* Test: initialize - role isolation                                       */
    /* admin only gets DEFAULT_ADMIN_ROLE; other roles must be granted         */
    /* explicitly (RouterFixture grants them in setUp(), but a fresh-init     */
    /* router with no extra grants should leave admin without them).           */
    /*------------------------------------------------------------------------*/

    function _freshRouter() internal returns (LoanRouterV2) {
        LoanRouterV2 impl = new LoanRouterV2(
            users.feeRecipient, address(collateralTimelock), address(depositTimelock), address(escrowTimelock)
        );
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(LoanRouterV2.initialize.selector, users.admin));
        return LoanRouterV2(address(proxy));
    }

    function test__Initialize_DoesNotGrantPauseAdminRole() public {
        LoanRouterV2 fresh = _freshRouter();
        assertFalse(fresh.hasRole(keccak256("PAUSE_ADMIN_ROLE"), users.admin));
    }

    function test__Initialize_DoesNotGrantLiquidatorRole() public {
        LoanRouterV2 fresh = _freshRouter();
        assertFalse(fresh.hasRole(keccak256("LIQUIDATOR_ROLE"), users.admin));
    }

    function test__Initialize_DoesNotGrantOriginatorRole() public {
        LoanRouterV2 fresh = _freshRouter();
        assertFalse(fresh.hasRole(keccak256("ORIGINATOR_ROLE"), users.admin));
    }

    /*------------------------------------------------------------------------*/
    /* Test: initialize - EIP-712 domain                                       */
    /*------------------------------------------------------------------------*/

    function test__Initialize_EIP712DomainNameAndVersion() public view {
        (, string memory name, string memory version,,,,) = router.eip712Domain();
        assertEq(name, "USDai Loan Router V2");
        assertEq(version, "1.0");
    }

    function test__Initialize_EIP712DomainChainIdMatches() public view {
        (,,, uint256 chainId, address verifyingContract,,) = router.eip712Domain();
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(router));
    }

    /*------------------------------------------------------------------------*/
    /* Test: initialize - pause state                                          */
    /*------------------------------------------------------------------------*/

    function test__Initialize_NotPausedInitially() public view {
        assertFalse(router.paused());
    }

    /*------------------------------------------------------------------------*/
    /* Test: initialize - ERC721 interface support                             */
    /*------------------------------------------------------------------------*/

    function test__Initialize_SupportsInterface_ERC721() public view {
        /* IERC721 interface ID = 0x80ac58cd */
        assertTrue(router.supportsInterface(0x80ac58cd));
    }
}
