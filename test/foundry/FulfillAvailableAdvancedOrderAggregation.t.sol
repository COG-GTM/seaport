// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import { Test } from "forge-std/Test.sol";

import {
    ConsiderationInterface
} from "seaport-types/src/interfaces/ConsiderationInterface.sol";

import {
    ItemType,
    OrderType
} from "seaport-types/src/lib/ConsiderationEnums.sol";

import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    FulfillmentComponent,
    OfferItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import {
    ReferenceConduitController
} from "../../reference/conduit/ReferenceConduitController.sol";

import {
    ReferenceConsideration
} from "../../reference/ReferenceConsideration.sol";

import { TestERC721 } from "../../contracts/test/TestERC721.sol";

/**
 * @dev Regression tests for aggregating consideration items across orders in
 *      fulfillAvailableAdvancedOrders on the reference implementation: every
 *      aggregated component must be marked spent, not just the first one.
 */
contract FulfillAvailableAdvancedOrderAggregation is Test {
    ConsiderationInterface seaport;
    TestERC721 nft;

    address payable creator = payable(makeAddr("creator"));
    address buyer = makeAddr("buyer");

    uint256[] sellerPks;
    address[] sellers;

    uint256 constant PRICE = 10 ether;
    uint256 constant CREATOR_FEE = 0.5 ether;

    function setUp() public {
        seaport = ConsiderationInterface(
            address(
                new ReferenceConsideration(
                    address(new ReferenceConduitController())
                )
            )
        );
        nft = new TestERC721();

        for (uint256 i = 0; i < 3; ++i) {
            (address seller, uint256 pk) = makeAddrAndKey(
                string(abi.encodePacked("seller", vm.toString(i)))
            );
            sellers.push(seller);
            sellerPks.push(pk);
            nft.mint(seller, i + 1);
            vm.prank(seller);
            nft.setApprovalForAll(address(seaport), true);
        }

        vm.deal(buyer, 1_000 ether);
    }

    function testSweepAggregatesCreatorFeesAcrossTwoOrders() public {
        _sweep(2);
    }

    function testSweepAggregatesCreatorFeesAcrossThreeOrders() public {
        _sweep(3);
    }

    function testSingleOrderViaFulfillAvailableAdvancedOrders() public {
        _sweep(1);
    }

    function _sweep(uint256 count) internal {
        uint256[] memory sellerBalancesBefore = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            sellerBalancesBefore[i] = sellers[i].balance;
        }
        uint256 creatorBalanceBefore = creator.balance;

        bool[] memory availableOrders = _fulfillAvailable(count);

        for (uint256 i = 0; i < count; ++i) {
            assertTrue(availableOrders[i]);
            assertEq(nft.ownerOf(i + 1), buyer);
            assertEq(
                sellers[i].balance - sellerBalancesBefore[i],
                PRICE - CREATOR_FEE
            );
        }
        assertEq(creator.balance - creatorBalanceBefore, CREATOR_FEE * count);
        assertEq(buyer.balance, 1_000 ether - PRICE * count);
    }

    function _fulfillAvailable(
        uint256 count
    ) internal returns (bool[] memory availableOrders) {
        AdvancedOrder[] memory orders = new AdvancedOrder[](count);
        for (uint256 i = 0; i < count; ++i) {
            orders[i] = _listing(i);
        }

        vm.prank(buyer);
        (availableOrders, ) = seaport.fulfillAvailableAdvancedOrders{
            value: PRICE * count
        }(
            orders,
            new CriteriaResolver[](0),
            _offerFulfillments(count),
            _considerationFulfillments(count),
            bytes32(0),
            buyer,
            count
        );
    }

    function _offerFulfillments(
        uint256 count
    ) internal pure returns (FulfillmentComponent[][] memory fulfillments) {
        fulfillments = new FulfillmentComponent[][](count);
        for (uint256 i = 0; i < count; ++i) {
            fulfillments[i] = new FulfillmentComponent[](1);
            fulfillments[i][0] = FulfillmentComponent(i, 0);
        }
    }

    /**
     * @dev One seller-proceeds group per order plus one creator-fee group
     *      aggregating consideration item 1 of every order.
     */
    function _considerationFulfillments(
        uint256 count
    ) internal pure returns (FulfillmentComponent[][] memory fulfillments) {
        fulfillments = new FulfillmentComponent[][](count + 1);
        fulfillments[count] = new FulfillmentComponent[](count);
        for (uint256 i = 0; i < count; ++i) {
            fulfillments[i] = new FulfillmentComponent[](1);
            fulfillments[i][0] = FulfillmentComponent(i, 0);
            fulfillments[count][i] = FulfillmentComponent(i, 1);
        }
    }

    function _listing(uint256 i) internal view returns (AdvancedOrder memory) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(ItemType.ERC721, address(nft), i + 1, 1, 1);

        ConsiderationItem[] memory consideration = new ConsiderationItem[](2);
        consideration[0] = ConsiderationItem(
            ItemType.NATIVE,
            address(0),
            0,
            PRICE - CREATOR_FEE,
            PRICE - CREATOR_FEE,
            payable(sellers[i])
        );
        consideration[1] = ConsiderationItem(
            ItemType.NATIVE,
            address(0),
            0,
            CREATOR_FEE,
            CREATOR_FEE,
            creator
        );

        OrderParameters memory parameters = OrderParameters(
            sellers[i],
            address(0),
            offer,
            consideration,
            OrderType.FULL_OPEN,
            block.timestamp,
            block.timestamp + 1,
            bytes32(0),
            i,
            bytes32(0),
            consideration.length
        );

        OrderComponents memory components = OrderComponents(
            parameters.offerer,
            parameters.zone,
            parameters.offer,
            parameters.consideration,
            parameters.orderType,
            parameters.startTime,
            parameters.endTime,
            parameters.zoneHash,
            parameters.salt,
            parameters.conduitKey,
            seaport.getCounter(sellers[i])
        );

        (, bytes32 domainSeparator, ) = seaport.information();
        bytes32 digest = keccak256(
            abi.encodePacked(
                bytes2(0x1901),
                domainSeparator,
                seaport.getOrderHash(components)
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sellerPks[i], digest);

        return AdvancedOrder(parameters, 1, 1, abi.encodePacked(r, s, v), "");
    }
}
