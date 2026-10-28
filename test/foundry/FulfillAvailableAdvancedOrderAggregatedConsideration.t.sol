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
    OfferItem,
    OrderParameters,
    ConsiderationItem,
    OrderComponents,
    FulfillmentComponent,
    CriteriaResolver
} from "seaport-types/src/lib/ConsiderationStructs.sol";

import { BaseOrderTest } from "./utils/BaseOrderTest.sol";

/**
 * @dev Regression tests for aggregating consideration items across multiple
 *      orders in fulfillAvailableAdvancedOrders (e.g. a sweep where every
 *      order pays a creator fee to the same recipient and those fee items are
 *      grouped into a single fulfillment component).
 */
contract FulfillAvailableAdvancedOrderAggregatedConsideration is
    BaseOrderTest
{
    uint256 internal constant PRICE = 1 ether;
    uint256 internal constant CREATOR_FEE = 0.05 ether;

    function testAggregatedCreatorFeesAcrossOrdersReference() public {
        _sweepWithAggregatedCreatorFees(referenceConsideration, 2);
    }

    function testAggregatedCreatorFeesAcrossOrdersOptimized() public {
        _sweepWithAggregatedCreatorFees(consideration, 2);
    }

    function testAggregatedCreatorFeesAcrossThreeOrdersReference() public {
        _sweepWithAggregatedCreatorFees(referenceConsideration, 3);
    }

    function testAggregatedCreatorFeesAcrossThreeOrdersOptimized() public {
        _sweepWithAggregatedCreatorFees(consideration, 3);
    }

    function testSingleOrderCreatorFeeReference() public {
        _sweepWithAggregatedCreatorFees(referenceConsideration, 1);
    }

    function testSingleOrderCreatorFeeOptimized() public {
        _sweepWithAggregatedCreatorFees(consideration, 1);
    }

    function _sweepWithAggregatedCreatorFees(
        ConsiderationInterface target,
        uint256 numOrders
    ) internal {
        AdvancedOrder[] memory advancedOrders = new AdvancedOrder[](numOrders);

        for (uint256 i = 0; i < numOrders; ++i) {
            uint256 tokenId = i + 1;
            test721_1.mint(alice, tokenId);
            advancedOrders[i] = _buildListing(target, tokenId);

            offerComponents.push(FulfillmentComponent(i, 0));
            offerComponentsArray.push(offerComponents);
            delete offerComponents;

            considerationComponents.push(FulfillmentComponent(i, 0));
            considerationComponentsArray.push(considerationComponents);
            delete considerationComponents;
        }

        // Aggregate every order's creator fee item into one component group.
        for (uint256 i = 0; i < numOrders; ++i) {
            considerationComponents.push(FulfillmentComponent(i, 1));
        }
        considerationComponentsArray.push(considerationComponents);
        delete considerationComponents;

        uint256 aliceBefore = alice.balance;
        uint256 calBefore = cal.balance;

        (bool[] memory availableOrders, ) = target
            .fulfillAvailableAdvancedOrders{
            value: (PRICE + CREATOR_FEE) * numOrders
        }(
            advancedOrders,
            new CriteriaResolver[](0),
            offerComponentsArray,
            considerationComponentsArray,
            bytes32(0),
            bob,
            numOrders
        );

        for (uint256 i = 0; i < numOrders; ++i) {
            assertTrue(availableOrders[i]);
            assertEq(test721_1.ownerOf(i + 1), bob);
        }
        assertEq(alice.balance - aliceBefore, PRICE * numOrders);
        assertEq(cal.balance - calBefore, CREATOR_FEE * numOrders);
    }

    function _buildListing(
        ConsiderationInterface target,
        uint256 tokenId
    ) internal returns (AdvancedOrder memory) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem(
            ItemType.ERC721,
            address(test721_1),
            tokenId,
            1,
            1
        );

        ConsiderationItem[] memory consider = new ConsiderationItem[](2);
        consider[0] = ConsiderationItem(
            ItemType.NATIVE,
            address(0),
            0,
            PRICE,
            PRICE,
            alice
        );
        consider[1] = ConsiderationItem(
            ItemType.NATIVE,
            address(0),
            0,
            CREATOR_FEE,
            CREATOR_FEE,
            cal
        );

        OrderParameters memory parameters = OrderParameters(
            alice,
            address(0),
            offer,
            consider,
            OrderType.FULL_OPEN,
            block.timestamp,
            block.timestamp + 1,
            bytes32(0),
            tokenId,
            bytes32(0),
            consider.length
        );

        OrderComponents memory components = getOrderComponents(
            parameters,
            target.getCounter(alice)
        );
        bytes memory signature = signOrder(
            target,
            alicePk,
            target.getOrderHash(components)
        );

        return AdvancedOrder(parameters, 1, 1, signature, "");
    }
}
