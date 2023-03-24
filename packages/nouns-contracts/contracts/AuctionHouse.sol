// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

// Whitelist contract to whitelist wallets for initial minting
contract Whitelist is Ownable {
    mapping(address => bool) public whitelist;

    function addToWhitelist(address wallet) public onlyOwner {
        whitelist[wallet] = true;
    }

    function removeFromWhitelist(address wallet) public onlyOwner {
        whitelist[wallet] = false;
    }
}

contract NounAuction is ERC721URIStorage, Ownable {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    // Minimum bid for each auction
    uint256 public minimumBid = 1 ether;

    // Struct to represent an ongoing auction
    struct Auction {
        uint256 tokenId;
        address payable highestBidder;
        uint256 highestBid;
        address payable secondHighestBidder;
        uint256 secondHighestBid;
        uint256 startTime;
        uint256 endTime;
    }

    // Mapping of token IDs to ongoing auctions
    mapping(uint256 => Auction) public auctions;

    // Set of ongoing auctions
    EnumerableSet.UintSet private ongoingAuctions;

    // Mapping of starting prices for each token ID
    mapping(uint256 => uint256) public startingPrices;

    // Mapping of auction durations for each token ID
    mapping(uint256 => uint256) public auctionDurations;

    // Mapping of locked funds by bidder
    mapping(address => uint256) public lockedFundsByBidder;

    // Whitelist contract for initial minting
    Whitelist public whitelistContract;

    // Event to be emitted when a new auction is created
    event AuctionCreated(uint256 tokenId, uint256 startingPrice, uint256 startTime, uint256 endTime);

    // Event to be emitted when an auction ends
    event AuctionEnded(uint256 tokenId, address winner, uint256 winningBid);

    constructor(address _whitelistContract) ERC721("NounAuction", "NA") {
        whitelistContract = Whitelist(_whitelistContract);
    }

    // Function to create new auction
    function createAuction(uint256 tokenId, uint256 startingPrice, uint256 duration) public {
        require(ownerOf(tokenId) == address(this), "Token not in auction house");
        require(duration > 0, "Auction duration must be greater than zero");

        Auction memory auction = Auction(
            tokenId,
            payable(address(0)),
            0,
            payable(address(0)),
            0,
            block.timestamp,
            block.timestamp.add(duration * 1 hours)
        );

        auctions[tokenId] = auction;
        ongoingAuctions.add(tokenId);

        // Set minimum bid for auction
        if (startingPrice < minimumBid) {
            startingPrice = minimumBid;
        }

        startingPrices[tokenId] = startingPrice;
        auctionDurations[tokenId] = duration;

        emit AuctionCreated(tokenId, startingPrice, block.timestamp, block.timestamp.add(duration * 1 hours));
    }

    // Function to place bid on ongoing auction
    function placeBid(uint256 tokenId) public payable {
        Auction storage auction = auctions[tokenId];

        require(ongoingAuctions.contains(tokenId), "Auction does not exist");
        require(block.timestamp < auction.endTime, "Auction has ended");
        require(
            msg.value >= auction.highestBid.add(minimumBid),
            "Bid must be higher than current highest bid"
        );

        if (auction.highestBidder != address(0)) {
            // Move current highest bidder to second highest bidder
            auction.secondHighestBidder = auction.highestBidder;
            auction.secondHighestBid = auction.highestBid;

            // Unlock second highest bidder's funds
            uint256 refundedFunds = auction.secondHighestBid;
            auction.secondHighestBid = 0;
            lockedFundsByBidder[auction.secondHighestBidder] = lockedFundsByBidder[auction.secondHighestBidder].sub(refundedFunds);
        }

        // Lock bidder's funds and update highest bidder
        auction.highestBidder = payable(msg.sender);
        auction.highestBid = msg.value;
        lockedFundsByBidder[msg.sender] = lockedFundsByBidder[msg.sender].add(msg.value);

        emit AuctionEnded(tokenId, msg.sender, msg.value);
    }

    // Function to end ongoing auction and transfer token to highest bidder
    function endAuction(uint256 tokenId) public {
        Auction storage auction = auctions[tokenId];

        require(ongoingAuctions.contains(tokenId), "Auction does not exist");
        require(block.timestamp >= auction.endTime, "Auction has not ended yet");

        if (auction.highestBidder == address(0)) {
            // Burn token if no bids were placed
            _burn(tokenId);
        } else {
            // Transfer token to highest bidder
            _transfer(address(this), auction.highestBidder, tokenId);

            // Calculate gas fee for transfer and allocate remaining funds to auction
            uint256 gasFee = tx.gasprice.mul(21000);
            uint256 remainingFunds = auction.highestBid.sub(gasFee);
            lockedFundsByBidder[auction.highestBidder] = lockedFundsByBidder[auction.highestBidder].sub(auction.highestBid).add(remainingFunds);
        }
            // Reset auction for token
        delete auctions[tokenId];
        ongoingAuctions.remove(tokenId);

            // Create new auction for next token
            createAuction(tokenId.add(1), startingPrices[tokenId], auctionDurations[tokenId]);

        emit AuctionEnded(tokenId, auction.highestBidder, auction.highestBid);
    }

    // Function to get highest bid for an ongoing auction
    function getHighestBid(uint256 tokenId) public view returns (uint256) {
        return auctions[tokenId].highestBid;
    }

    // Function to withdraw locked funds by bidder
    function withdraw() public {
        uint256 lockedFunds = lockedFundsByBidder[msg.sender];
        require(lockedFunds > 0, "No locked funds");

        lockedFundsByBidder[msg.sender] = 0;
        payable(msg.sender).transfer(lockedFunds);
    }

    // Function to whitelist wallets for initial minting
    function addToWhitelist(address wallet) public onlyOwner {
        whitelistContract.addToWhitelist(wallet);
    }

    function removeFromWhitelist(address wallet) public onlyOwner {
        whitelistContract.removeFromWhitelist(wallet);
    }

    // Function to mint token to specified wallet address
    function mintTo(address to, uint256 tokenId, string memory tokenURI) public {
        require(whitelistContract.whitelist(msg.sender), "Not whitelisted for initial minting");
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, tokenURI);
    }

    // Function to change auction duration
    function setAuctionDuration(uint256 tokenId, uint256 duration) public onlyOwner {
        require(ownerOf(tokenId) == address(this), "Token not in auction house");
        require(ongoingAuctions.contains(tokenId) == false, "Cannot change duration of ongoing auction");
        require(duration > 0, "Auction duration must be greater than zero");
        auctionDurations[tokenId] = duration;
    }