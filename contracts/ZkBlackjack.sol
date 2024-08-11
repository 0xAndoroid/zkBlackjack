// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {ImageID} from "./ImageID.sol"; // auto-generated contract after running `cargo build`.

contract ZkBlackjack {
    /// IMMUTABLES ///

    IRiscZeroVerifier public immutable verifier;
    bytes32 public constant imageId = ImageID.BLACKJACK_ID;

    /// STRUCTS ///

    struct Dealer {
        address payable addr;
        bool online;
        /// Balance of the dealer
        uint256 balance;
        /// Locked balance of the dealer currently in games
        uint256 lockedBalance;
        /// Randomness commitment from dealer side
        bytes32 commitment;
        /// Minimum bet
        uint256 minBet;
        /// Maximum bet
        uint256 maxBet;
        /// Fee for the game
        uint256 fee;
        /// Banned dealer; can't start new games
        bool banned;
        /// Timeout number of blocks after which the user can reclaim the game
        uint256 timeoutBlocks;
    }

    struct Game {
        bool finished;
        address dealer;
        address payable player;
        bytes32 dealerCommitment;
        bytes32 playerCommitment;
        bytes playerPublicKey;
        /// Total amonut won by the player (including the bet)
        uint256 playerWin;
        uint256[] bets;
        uint8[] doubleHands;
        uint8[] splitHands;
        /// Block number when the game was created. Used for timeout to prevent dealer from stalling
        uint256 gameStartBlock;
    }

    /// Deserialization of RISC0 journal
    struct Output {
        bytes32 dealerCommitment;
        bytes32[] playerCommitments;
        bytes[] playerPubkeys;
        uint256[] payouts;
        uint8[][] doubleHands;
        uint8[][] splitHands;
    }

    /// EVENTS ///

    event GameStarted(
        address indexed player,
        uint256 indexed gameId,
        address indexed dealer
    );
    event GameResult(
        address indexed player,
        uint256 indexed gameId,
        address indexed dealer,
        uint256 playerBet,
        uint256 playerWin
    );

    /// ERRORS ///
    error NotADealer();
    error NotADealerOfThisGame();
    error DealerIsNotOnline();
    error DealerIsOnline();
    error IsNotWhitelisted();
    error DealerAlreadyRegistered();
    error DealerHasPendingGame();
    error GameAlreadyFinished();
    error DealerIsBroke();

    // Start game errors
    error BetIsTooLow();
    error BetIsTooHigh();
    error BetsDoNotMatch();

    // Transfer winnings errors
    error TransferredArleady();

    // Proof verification error
    error InvalidProof();
    error InvalidProofMetadata();

    // Reclaim game error
    error TimeoutNotReached();
    error SenderIsNotPlayerOfTheGame();

    /// MODIFIERS ///

    /// onlyDealer
    modifier onlyDealer() {
        require(dealers[msg.sender].addr == msg.sender, NotADealer());
        _;
    }

    modifier onlyDealerOfTheGame(uint256 _gameId) {
        require(games[_gameId].dealer == msg.sender, NotADealerOfThisGame());
        _;
    }

    modifier onlyDealerOfTheGames(uint256[] calldata _gameIds) {
        for (uint256 i = 0; i < _gameIds.length; i++) {
            require(
                games[_gameIds[i]].dealer == msg.sender,
                NotADealerOfThisGame()
            );
        }
        _;
    }

    modifier onlyOnlineDealer() {
        require(dealers[msg.sender].addr == msg.sender, NotADealer());
        require(dealers[msg.sender].online, DealerIsNotOnline());
        _;
    }

    modifier onlyOfflineDealer() {
        require(dealers[msg.sender].addr == msg.sender, NotADealer());
        require(!dealers[msg.sender].online, DealerIsOnline());
        _;
    }

    modifier allowedToRegisterDealer() {
        require(dealerWhitelist[msg.sender], IsNotWhitelisted());
        _;
    }

    /// STATE ///

    /// Mapping from game id to game
    mapping(uint256 => Game) public games;
    /// New game index
    uint256 public newGameId;
    /// Online games
    uint256[] public onlineGames;

    /// Dealers
    mapping(address => Dealer) public dealers;
    /// Online dealers that are accepting new games
    address[] public onlineDealers;

    /// Whitelist for registering a dealer
    mapping(address => bool) public dealerWhitelist;

    constructor(IRiscZeroVerifier _verifier) {
        verifier = _verifier;
    }

    /// PLAYER FUNCTIONS ///

    function startGame(
        address _dealer,
        uint256[] calldata _initBets,
        bytes32 _playerCommitment,
        bytes32 _playerPublicKey
    ) external payable {
        require(dealers[_dealer].addr == _dealer, NotADealer());
        require(dealers[_dealer].online, DealerIsNotOnline());
        require(dealers[_dealer].banned == false, NotADealer());
        uint256 totalBet = 0;
        for (uint256 i = 0; i < _initBets.length; i++) {
            require(_initBets[i] >= dealers[_dealer].minBet, BetIsTooLow());
            require(_initBets[i] <= dealers[_dealer].maxBet, BetIsTooHigh());
            totalBet += _initBets[i];
        }
        require(msg.value == totalBet, BetsDoNotMatch());

        Game storage game = games[newGameId];
        game.dealer = _dealer;
        game.player = payable(msg.sender);
        game.bets = _initBets;
        game.playerCommitment = _playerCommitment;
        game.dealerCommitment = dealers[_dealer].commitment;
        game.playerPublicKey = abi.encode(_playerPublicKey);
        game.gameStartBlock = block.number;

        _lockBalance(_dealer, totalBet);

        emit GameStarted(msg.sender, newGameId, _dealer);
        newGameId++;
    }

    /// Player calls this function to double the bet on ONE OF his hands
    /// If split is not possible, the function does nothing and player loses the bet
    /// Reverts if dealer doesn't have enough money to match the bet
    function double(uint256 _gameId, uint256 _handIndex) external payable {}

    /// Player call this function to split the hand
    /// If split is not possible, the function does nothing and player loses the bet
    /// Reverts if dealer doesn't have enough money to match the bet
    function split(uint256 _gameId, uint256 _handIndex) external payable {}

    /// DEALER FUNCTIONS ///

    function registerDealer(
        uint256 _minBet,
        uint256 _maxBet,
        uint256 _fee,
        uint256 _timeoutBlocks,
        bytes32 _commitment
    ) external allowedToRegisterDealer {
        require(
            dealers[msg.sender].addr == address(0),
            DealerAlreadyRegistered()
        );

        dealers[msg.sender] = Dealer({
            addr: payable(msg.sender),
            online: false,
            balance: 0,
            lockedBalance: 0,
            commitment: _commitment,
            minBet: _minBet,
            maxBet: _maxBet,
            fee: _fee,
            banned: false,
            timeoutBlocks: _timeoutBlocks
        });
    }

    function updateCommitment(bytes32 _commitment) external onlyDealer {
        dealers[msg.sender].commitment = _commitment;
    }

    function setFee(uint256 _fee) external onlyOfflineDealer {
        dealers[msg.sender].fee = _fee;
    }

    function setBetLimits(
        uint256 _minBet,
        uint256 _maxBet
    ) external onlyOfflineDealer {
        dealers[msg.sender].minBet = _minBet;
        dealers[msg.sender].maxBet = _maxBet;
    }

    function goOnline() external onlyOfflineDealer {
        dealers[msg.sender].online = true;
        onlineDealers.push(msg.sender);
    }

    function goOffline() external onlyOnlineDealer {
        // check that dealer doesn't have any games pending
        for (uint256 i = 0; i < onlineGames.length; i++) {
            if (games[onlineGames[i]].dealer == msg.sender) {
                revert DealerHasPendingGame();
            }
        }
        // sanity-check. should be good after the previous loop
        require(dealers[msg.sender].lockedBalance == 0, DealerHasPendingGame());
        dealers[msg.sender].online = false;
        for (uint256 i = 0; i < onlineDealers.length; i++) {
            if (onlineDealers[i] == msg.sender) {
                onlineDealers[i] = onlineDealers[onlineDealers.length - 1];
                onlineDealers.pop();
                break;
            }
        }
    }

    function withdraw(uint256 _amount) external onlyOfflineDealer {
        require(dealers[msg.sender].balance >= _amount, DealerIsBroke());
        dealers[msg.sender].balance -= _amount;
        payable(msg.sender).transfer(_amount);
    }

    function deposit() external payable onlyOfflineDealer {
        dealers[msg.sender].balance += msg.value;
    }

    /// FUNCTION SETTLING THE GAME ///

    /// Dealer is supposed to voluntarily call this function to transfer the win to the player
    /// so that player doesn't have to wait for them to settle the zkp of the game
    /// If the dealer transfers too much, this is a problem of the dealer, and user got lucky
    function transferWinningsToUser(
        uint256 _gameId,
        uint256 _payout
    ) external onlyDealerOfTheGame(_gameId) {
        Game storage game = games[_gameId];
        require(!game.finished, GameAlreadyFinished());
        require(game.playerWin == 0, TransferredArleady());
        require(
            _payout >=
                dealers[msg.sender].balance - dealers[msg.sender].lockedBalance,
            DealerIsBroke()
        );
        game.playerWin = _payout;
        // balance remains locked, will be unlocked after proof (in case dealer transferred too much)
        // payout substracted from dealer's balance, will be credited back after proof
        dealers[msg.sender].balance -= _payout;
        game.player.transfer(_payout);
    }

    /// Prove several games at once using a single RISC0 proof
    function proveGames(
        uint256[] calldata _gameIds,
        Output calldata _output,
        bytes memory _seal
    ) external onlyDealerOfTheGames(_gameIds) {
        verifyProof(_gameIds, _output, _seal);

        for (uint256 i = 0; i < _gameIds.length; i++) {
            Game storage game = games[_gameIds[i]];
            uint256 allBets = totalBets(_gameIds[i]);
            dealers[game.dealer].balance += allBets;
            game.finished = true;
            emit GameResult(
                game.player,
                _gameIds[i],
                msg.sender,
                allBets,
                game.playerWin
            );
            // Transfer the winnings to the player if haven't yet
            if (_output.payouts[i] > game.playerWin) {
                // Dealer hasn't transferred the winnings to the player yet
                // Transfer the winnings to the player
                uint256 payout = _output.payouts[i] - game.playerWin;
                game.playerWin = _output.payouts[i];
                _unlockBalance(_gameIds[i]);
                game.player.transfer(payout);
            } else {
                // Dealer has transferred more than the winnings to the player
                // It's their problem, unfortunatelly
                // Anyway, unlock the balance
                _unlockBalance(_gameIds[i]);
            }
        }
    }

    /// Can be called by the player if the dealer is not submitting proof for a long time
    /// The player receives 2.5x of the total bet they put in from dealer's balance
    /// (as if they had blackjack in all hands)
    /// And dealer is banned so that they can't start new games
    function reclaimGame(uint256 _gameId) external {
        Game storage game = games[_gameId];
        require(!game.finished, GameAlreadyFinished());
        require(game.player == msg.sender, SenderIsNotPlayerOfTheGame());
        require(
            block.number >
                game.gameStartBlock + dealers[game.dealer].timeoutBlocks,
            TimeoutNotReached()
        );

        uint256 allBets = totalBets(_gameId);
        uint256 payout = (allBets * 5) / 2;
        game.playerWin = payout;
        game.finished = true;
        dealers[game.dealer].banned = true;
        dealers[game.dealer].balance += allBets;
        dealers[game.dealer].balance -= payout;

        _unlockBalance(_gameId);

        emit GameResult(msg.sender, _gameId, game.dealer, allBets, payout);
        game.player.transfer(payout);
    }

    function _unlockBalance(uint256 _gameId) internal {
        uint256 locked = getLocked(totalBets(_gameId));
        dealers[games[_gameId].dealer].lockedBalance -= locked;
    }

    function _lockBalance(address dealer, uint256 newBet) internal {
        dealers[dealer].lockedBalance += getLocked(newBet);
        require(
            dealers[dealer].lockedBalance <= dealers[dealer].balance,
            DealerIsBroke()
        );
    }

    function totalBets(uint256 gameId) public view returns (uint256) {
        uint256 totalBet = 0;
        Game storage game = games[gameId];
        for (uint256 i = 0; i < game.bets.length; i++) {
            totalBet += game.bets[i];
        }
        return totalBet;
    }

    function verifyProof(
        uint256[] calldata _gameIds,
        Output calldata _output,
        bytes memory _seal
    ) internal view {
        bytes memory journal = abi.encode(_output);
        ///////////////////////////////
        /// RISC0 proof verification///
        ///////////////////////////////
        verifier.verify(_seal, imageId, sha256(journal));
        for (uint256 i = 0; i < _gameIds.length; i++) {
            Game storage game = games[_gameIds[i]];
            require(!game.finished, GameAlreadyFinished());
            require(
                keccak256(_output.playerPubkeys[i]) ==
                    keccak256(game.playerPublicKey),
                InvalidProofMetadata()
            );
            require(
                _output.dealerCommitment == game.dealerCommitment,
                InvalidProofMetadata()
            );
            require(
                _output.playerCommitments[i] == game.playerCommitment,
                InvalidProofMetadata()
            );
            require(
                keccak256(abi.encode(_output.doubleHands[i])) ==
                    keccak256(abi.encode(game.doubleHands)),
                InvalidProofMetadata()
            );
            require(
                keccak256(abi.encode(_output.splitHands)) ==
                    keccak256(abi.encode(game.splitHands)),
                InvalidProofMetadata()
            );
        }
    }

    function getLocked(uint256 bet) internal pure returns (uint256) {
        // 1.5x should be enough, but I don't want to deal with division rounding edge cases
        // - who cares about dealers anyway?
        // - oh, technically I'm the dealer
        // - well, I don't care about myself
        return bet * 2;
    }
}
