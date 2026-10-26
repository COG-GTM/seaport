// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {
    OrderType,
    ItemType
} from "seaport-types/src/lib/ConsiderationEnums.sol";

import {
    ConsiderationInterface
} from "seaport-types/src/interfaces/ConsiderationInterface.sol";

import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    FulfillmentComponent,
    OfferItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import { BaseOrderTest } from "./utils/BaseOrderTest.sol";

/**
 * @dev Regression tests for aggregating consideration items that span
 *      multiple orders into a single fulfillment component group (e.g. a
 *      marketplace "sweep" where every listing pays creator earnings to the
 *      same recipient). Every aggregated item must be marked as spent;
 *      otherwise the order combiner reverts with ConsiderationNotMet.
 */
contract FulfillAvailableAggregatedConsiderationTest is BaseOrderTest {
    uint256 constant CREATOR_FEE_BPS = 500;

    function _price(uint256 orderIndex) internal pure returns (uint256) {
        return (orderIndex + 1) * 1 ether;
    }

    function _creatorFee(uint256 orderIndex) internal pure returns (uint256) {
        return (_price(orderIndex) * CREATOR_FEE_BPS) / 10_000;
    }

    function _seller(uint256 orderIndex) internal view returns (address) {
        return orderIndex % 2 == 0 ? alice : bob;
    }

    function _sellerPk(uint256 orderIndex) internal view returns (uint256) {
        return orderIndex % 2 == 0 ? alicePk : bobPk;
    }

    /**
     * @dev Build `count` ERC721 listings, each paying seller proceeds
     *      (item 0) and creator earnings to `cal` (item 1).
     */
    function _buildListings(
        ConsiderationInterface target,
        uint256 count
    ) internal returns (AdvancedOrder[] memory orders, uint256 totalValue) {
        orders = new AdvancedOrder[](count);
        for (uint256 i = 0; i < count; ++i) {
            address seller = _seller(i);
            uint256 tokenId = 100 + i;
            test721_1.mint(seller, tokenId);

            OfferItem[] memory offer = new OfferItem[](1);
            offer[0] = OfferItem(
                ItemType.ERC721,
                address(test721_1),
                tokenId,
                1,
                1
            );

            ConsiderationItem[] memory items = new ConsiderationItem[](2);
            items[0] = ConsiderationItem(
                ItemType.NATIVE,
                address(0),
                0,
                _price(i) - _creatorFee(i),
                _price(i) - _creatorFee(i),
                payable(seller)
            );
            items[1] = ConsiderationItem(
                ItemType.NATIVE,
                address(0),
                0,
                _creatorFee(i),
                _creatorFee(i),
                payable(cal)
            );
            totalValue += _price(i);

            OrderParameters memory parameters = OrderParameters(
                seller,
                address(0),
                offer,
                items,
                OrderType.FULL_OPEN,
                block.timestamp,
                block.timestamp + 1,
                bytes32(0),
                i,
                bytes32(0),
                items.length
            );
            OrderComponents memory components = OrderComponents(
                seller,
                address(0),
                offer,
                items,
                OrderType.FULL_OPEN,
                block.timestamp,
                block.timestamp + 1,
                bytes32(0),
                i,
                bytes32(0),
                target.getCounter(seller)
            );
            bytes memory signature = signOrder(
                target,
                _sellerPk(i),
                target.getOrderHash(components)
            );
            orders[i] = AdvancedOrder(parameters, 1, 1, signature, "");
        }
    }

    /**
     * @dev One offer group per NFT, one seller-proceeds group per order and a
     *      single group aggregating every order's creator earnings.
     */
    function _sweepFulfillments(
        uint256 count
    )
        internal
        pure
        returns (
            FulfillmentComponent[][] memory offerGroups,
            FulfillmentComponent[][] memory considerationGroups
        )
    {
        offerGroups = new FulfillmentComponent[][](count);
        considerationGroups = new FulfillmentComponent[][](count + 1);
        FulfillmentComponent[] memory creatorFees = new FulfillmentComponent[](
            count
        );
        for (uint256 i = 0; i < count; ++i) {
            offerGroups[i] = new FulfillmentComponent[](1);
            offerGroups[i][0] = FulfillmentComponent(i, 0);
            considerationGroups[i] = new FulfillmentComponent[](1);
            considerationGroups[i][0] = FulfillmentComponent(i, 0);
            creatorFees[i] = FulfillmentComponent(i, 1);
        }
        considerationGroups[count] = creatorFees;
    }

    function _expectedCreatorFees(
        uint256 count
    ) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < count; ++i) {
            total += _creatorFee(i);
        }
    }

    function _fulfill(
        ConsiderationInterface target,
        uint256 count
    ) internal returns (bool[] memory availableOrders) {
        (AdvancedOrder[] memory orders, uint256 totalValue) = _buildListings(
            target,
            count
        );
        (
            FulfillmentComponent[][] memory offerGroups,
            FulfillmentComponent[][] memory considerationGroups
        ) = _sweepFulfillments(count);

        (availableOrders, ) = target.fulfillAvailableAdvancedOrders{
            value: totalValue
        }(
            orders,
            new CriteriaResolver[](0),
            offerGroups,
            considerationGroups,
            bytes32(0),
            address(this),
            count
        );
    }

    function _sweep(ConsiderationInterface target, uint256 count) internal {
        uint256 creatorBalanceBefore = cal.balance;

        bool[] memory availableOrders = _fulfill(target, count);

        for (uint256 i = 0; i < count; ++i) {
            assertTrue(availableOrders[i]);
            assertEq(test721_1.ownerOf(100 + i), address(this));
        }
        assertEq(
            cal.balance - creatorBalanceBefore,
            _expectedCreatorFees(count)
        );
    }

    function testReferenceSweepAggregatesCreatorFeesAcrossTwoOrders() public {
        _sweep(referenceConsideration, 2);
    }

    function testReferenceSweepAggregatesCreatorFeesAcrossFiveOrders() public {
        _sweep(referenceConsideration, 5);
    }

    function testReferenceSingleOrderViaFulfillAvailable() public {
        _sweep(referenceConsideration, 1);
    }

    function testOptimizedSweepAggregatesCreatorFeesAcrossTwoOrders() public {
        _sweep(consideration, 2);
    }

    function testOptimizedSweepAggregatesCreatorFeesAcrossFiveOrders() public {
        _sweep(consideration, 5);
    }

    function testOptimizedSingleOrderViaFulfillAvailable() public {
        _sweep(consideration, 1);
    }
}
