// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {RiscZeroCheats} from "risc0/test/RiscZeroCheats.sol";
import {console2} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {ZkBlackjack} from "../contracts/ZkBlackjack.sol";
import {Elf} from "./Elf.sol"; // auto-generated contract after running `cargo build`.

contract ZkBlackjackTest is RiscZeroCheats, Test {
    ZkBlackjack zkBlackjack;
    address dealer = 0x1234567890123456789012345678901234567890;
    address registerAuthority = 0x2345678901234567890123456789012345678901;
    address player = 0x3456789012345678901234567890123456789012;

    bytes16 dealerSeed = "dealerSeed";
    bytes16 playerSeed = "playerSeed";
    bytes16 dealerSeed2 = "dealerSeed2";

    function setUp() public {
        IRiscZeroVerifier verifier = deployRiscZeroVerifier();
        zkBlackjack = new ZkBlackjack(verifier, registerAuthority);
        hoax(registerAuthority, 100 ether);
        zkBlackjack.setDealerWhitelist(dealer, true);
        vm.startPrank(dealer);
        zkBlackjack.registerDealer(
            1 ether,
            10 ether,
            0 ether,
            1000,
            sha256(abi.encodePacked(dealerSeed))
        );
        vm.deal(dealer, 1000 ether);
        zkBlackjack.deposit{value: 100 ether}();
        zkBlackjack.goOnline();
    }

    struct Input {
        bytes16 dealerSeed;
        GameInput[] games;
    }

    struct GameInput {
        bytes16 playerSeed;
        bytes pubkey;
        uint8 initialHands;
        uint256[] bets;
        DeAction[] actions;
        bytes32[2][] signatures;
    }

    struct DeAction {
        uint8 nonce;
        uint8 handId;
        uint8 inner;
        uint8[] myCards;
        uint8[] dealerCards;
    }

    function test_stand() public {
        uint256[] memory bets = new uint256[](1);
        bets[0] = 1 ether;
        DeAction[] memory actions = new DeAction[](0);
        bytes32[2][] memory signatures = new bytes32[2][](0);

        bytes memory pubkey = hex"04b5789617d2b152815256faa4a995d9d08a7ead3deae3e9356d51f6b0ff6caa45c21944b0f47365a2c1d0b4c5237f3e3322dc6ea4cf4a9c41818f692e4e348633";
        GameInput[] memory games = new GameInput[](1);
        GameInput memory gameInput = GameInput({
            playerSeed: playerSeed,
            pubkey: pubkey,
            initialHands: 1,
            bets: bets,
            actions: actions,
            signatures: signatures
        });
        games[0] = gameInput;

        Input memory input = Input({dealerSeed: dealerSeed, games: games});

        (bytes memory journal, bytes memory seal) = prove(
            Elf.BLACKJACK_PATH,
            abi.encode(input)
        );

        uint256[] memory gameIds = new uint256[](1);
        gameIds[0] = 0;
        ZkBlackjack.Output memory output = abi.decode(
            journal,
            (ZkBlackjack.Output)
        );

        bytes32 playerCommitment = sha256(abi.encodePacked(playerSeed));
        vm.startPrank(player);
        vm.deal(player, 1 ether);
        zkBlackjack.startGame{value: 1 ether}(dealer, bets, playerCommitment, pubkey);
        
        assertEq(player.balance, 0 ether);
        
        vm.startPrank(dealer);
        zkBlackjack.proveGames(gameIds, output, seal);

        // Somehow with these pre-defined seeds, the player got a blackjack.
        // what are the odds of this happening?
        assertEq(player.balance, 2.5 ether);
    }

    function test_double() public {
        uint256[] memory bets = new uint256[](1);
        bets[0] = 1 ether;
        DeAction[] memory actions = new DeAction[](1);
        uint8[] memory myCards = new uint8[](2);
        myCards[0] = 3;
        myCards[1] = 4;
        uint8[] memory dealerCards = new uint8[](2);
        dealerCards[0] = 5;
        dealerCards[1] = 10;
        actions[0] = DeAction(0, 0, 2, myCards, dealerCards);
        bytes32[2][] memory signatures = new bytes32[2][](1);
        signatures[0] = [
            bytes32(0x3765d536a945e744a208c1f7107adb10ca467fd056cd25809ca1ca18f37e7f3a),
            bytes32(0x5398c0461fb9e71f3c6f98e4aa02a5b8759ee7451f268bf31371c853fb8d08e9)
        ];

        bytes memory pubkey = hex"0472b1b25d19128778cdc636a105cdbdf3e0e8435cba8474fac49f7231e0ff798303cd3bb9e88f9704e2aa5f1f2a2d7a2bc73496772839504b0f7995979cad6166";
        GameInput[] memory games = new GameInput[](1);
        GameInput memory gameInput = GameInput({
            playerSeed: playerSeed,
            pubkey: pubkey,
            initialHands: 1,
            bets: bets,
            actions: actions,
            signatures: signatures
        });
        games[0] = gameInput;

        Input memory input = Input({dealerSeed: dealerSeed2, games: games});

        (bytes memory journal, bytes memory seal) = prove(
            Elf.BLACKJACK_PATH,
            abi.encode(input)
        );

        uint256[] memory gameIds = new uint256[](1);
        gameIds[0] = 0;
        ZkBlackjack.Output memory output = abi.decode(
            journal,
            (ZkBlackjack.Output)
        );

        vm.startPrank(dealer);
        zkBlackjack.updateCommitment(sha256(abi.encodePacked(dealerSeed2)));

        bytes32 playerCommitment = sha256(abi.encodePacked(playerSeed));
        vm.startPrank(player);
        vm.deal(player, 4 ether);
        zkBlackjack.startGame{value: 1 ether}(dealer, bets, playerCommitment, pubkey);
        zkBlackjack.double{value: 1 ether}(0, 0);
        // playing decided to make impossible action, should just lose money lol.
        zkBlackjack.double{value: 2 ether}(0, 0);
        
        assertEq(player.balance, 0 ether);
        
        vm.startPrank(dealer);
        zkBlackjack.proveGames(gameIds, output, seal);

        // Somehow with these pre-defined seeds, the player got pushed.
        // Idk why I'm so lucky. Prob should go to casino.
        assertEq(player.balance, 2 ether);
    }
}
