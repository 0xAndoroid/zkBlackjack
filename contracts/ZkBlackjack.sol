// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";
import {ImageID} from "./ImageID.sol"; // auto-generated contract after running `cargo build`.

contract ZkBlackjack {
    /// IMMUTABLES ///

    IRiscZeroVerifier public immutable verifier;
    bytes32 public constant imageId = ImageID.BLACKJACK_ID;

    address public immutable registerAuthority;

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

    /// MODIFIERS ///

    /// onlyDealer
    modifier onlyDealer() {
        require(dealers[msg.sender].addr == msg.sender, "not a dealer");
        _;
    }

    modifier onlyDealerOfTheGame(uint256 _gameId) {
        require(
            games[_gameId].dealer == msg.sender,
            "not a dealer of this game"
        );
        _;
    }

    modifier onlyDealerOfTheGames(uint256[] calldata _gameIds) {
        for (uint256 i = 0; i < _gameIds.length; i++) {
            require(
                games[_gameIds[i]].dealer == msg.sender,
                "not a dealer of this game"
            );
        }
        _;
    }

    modifier onlyOnlineDealer() {
        require(dealers[msg.sender].addr == msg.sender, "not a dealer");
        require(dealers[msg.sender].online, "dealer is not online");
        _;
    }

    modifier onlyOfflineDealer() {
        require(dealers[msg.sender].addr == msg.sender, "not a dealer");
        require(!dealers[msg.sender].online, "dealer is online");
        _;
    }

    modifier allowedToRegisterDealer() {
        require(dealerWhitelist[msg.sender], "not allowed to register dealer");
        _;
    }

    modifier onlyRegisterAuthority() {
        require(msg.sender == registerAuthority, "not a register authority");
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

    constructor(IRiscZeroVerifier _verifier, address _registerAuthority) {
        verifier = _verifier;
        registerAuthority = _registerAuthority;
    }

    /// ADMIN FUNCTIONS ///

    function setDealerWhitelist(
        address _dealer,
        bool _able
    ) external onlyRegisterAuthority {
        dealerWhitelist[_dealer] = _able;
    }

    function banDealer(address _dealer) external onlyRegisterAuthority {
        dealers[_dealer].banned = true;
    }

    function unbanDealer(address _dealer) external onlyRegisterAuthority {
        dealers[_dealer].banned = false;
    }

    /// PLAYER FUNCTIONS ///

    function startGame(
        address _dealer,
        uint256[] calldata _initBets,
        bytes32 _playerCommitment,
        bytes calldata _playerPublicKey
    ) external payable {
        require(dealers[_dealer].addr == _dealer, "not a dealer");
        require(dealers[_dealer].online, "dealer is not online");
        require(dealers[_dealer].banned == false, "not a dealer");
        uint256 totalBet = 0;
        for (uint256 i = 0; i < _initBets.length; i++) {
            require(_initBets[i] >= dealers[_dealer].minBet, "bet is too low");
            require(_initBets[i] <= dealers[_dealer].maxBet, "bet is too high");
            totalBet += _initBets[i];
        }
        require(msg.value == totalBet, "msg.value not equal total bet");

        Game storage game = games[newGameId];
        game.dealer = _dealer;
        game.player = payable(msg.sender);
        game.bets = _initBets;
        game.playerCommitment = _playerCommitment;
        game.dealerCommitment = dealers[_dealer].commitment;
        game.playerPublicKey = _playerPublicKey;
        game.gameStartBlock = block.number;

        _lockBalance(_dealer, totalBet);

        emit GameStarted(msg.sender, newGameId, _dealer);
        newGameId++;
    }

    /// Player calls this function to double the bet on ONE OF his hands
    /// If split is not possible, the function does nothing and player loses the bet
    /// Reverts if dealer doesn't have enough money to match the bet
    function double(uint256 _gameId, uint8 _handIndex) external payable {
        Game storage game = games[_gameId];
        require(game.player == msg.sender, "not a player");
        require(!game.finished, "game already finished");
        require(_handIndex < game.bets.length, "invalid hand index");
        require(msg.value == game.bets[_handIndex], "msg.value not equal bet");
        require(
            dealers[game.dealer].balance - dealers[game.dealer].lockedBalance >=
                getLocked(msg.value),
            "dealer is broke"
        );
        game.bets[_handIndex] += msg.value;
        game.doubleHands.push(_handIndex);
        _lockBalance(game.dealer, msg.value);
    }

    /// Player call this function to split the hand
    /// If split is not possible, the function does nothing and player loses the bet
    /// Reverts if dealer doesn't have enough money to match the bet
    function split(uint256 _gameId, uint8 _handIndex) external payable {
        Game storage game = games[_gameId];
        require(game.player == msg.sender, "not a player");
        require(!game.finished, "game already finished");
        require(_handIndex < game.bets.length, "invalid hand index");
        require(msg.value == game.bets[_handIndex], "msg.value not equal bet");
        require(
            dealers[game.dealer].balance - dealers[game.dealer].lockedBalance >=
                getLocked(msg.value),
            "dealer is broke"
        );
        game.bets.push(game.bets[game.bets.length - 1]);
        for (uint256 i = game.bets.length - 1; i > _handIndex; i--) {
            game.bets[i] = game.bets[i - 1];
        }
        game.bets[_handIndex + 1] = msg.value;
        game.splitHands.push(_handIndex);
        _lockBalance(game.dealer, msg.value);
    }

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
            "dealer already registered"
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
                revert("dealer has pending games");
            }
        }
        // sanity-check. should be good after the previous loop
        require(
            dealers[msg.sender].lockedBalance == 0,
            "dealer has locked balance"
        );
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
        require(dealers[msg.sender].balance >= _amount, "dealer is broke");
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
        require(!game.finished, "game already finished");
        require(game.playerWin == 0, "winnings already transferred");
        require(
            _payout >=
                dealers[msg.sender].balance - dealers[msg.sender].lockedBalance,
            "dealer is broke"
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
            // Transfer the winnings to the player if haven't yet
            if (_output.payouts[i] > game.playerWin) {
                // Dealer hasn't transferred the winnings to the player yet
                // Transfer the winnings to the player
                uint256 payout = _output.payouts[i] - game.playerWin;
                game.playerWin = _output.payouts[i];
                _unlockBalance(_gameIds[i]);
                game.player.transfer(payout);
                emit GameResult(
                    game.player,
                    _gameIds[i],
                    msg.sender,
                    allBets,
                    payout
                );
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
        require(!game.finished, "game already finished");
        require(game.player == msg.sender, "not a player");
        require(
            block.number >
                game.gameStartBlock + dealers[game.dealer].timeoutBlocks,
            "timeout not reached"
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
            "dealer is broke"
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
            require(!game.finished, "game already finished");
            require(
                keccak256(_output.playerPubkeys[i]) ==
                    keccak256(game.playerPublicKey),
                "invalid proof player pubkey"
            );
            require(
                _output.dealerCommitment == game.dealerCommitment,
                "invalid proof dealer commitment"
            );
            require(
                _output.playerCommitments[i] == game.playerCommitment,
                "invalid proof player commitment"
            );
            // There's an interesting attack vector here:
            // Player could submit more actions onchain than offchain to the dealer
            // and then proof would fail. To fix this we need to verify that 
            // the actions in the proof are a subset of actions paid by the player
            for (uint256 j = 0; j < _output.doubleHands[i].length; j++) {
                // check if there exists a double action in the game
                bool found = false;
                for (uint256 k = 0; k < game.doubleHands.length; k++) {
                    if (_output.doubleHands[i][j] == game.doubleHands[k]) {
                        found = true;
                        break;
                    }
                }
                require(found, "invalid proof double hands");
            }
            for (uint256 j = 0; j < _output.splitHands[i].length; j++) {
                // check if there exists a split action in the game
                bool found = false;
                for (uint256 k = 0; k < game.splitHands.length; k++) {
                    if (_output.splitHands[i][j] == game.splitHands[k]) {
                        found = true;
                        break;
                    }
                }
                require(found, "invalid proof split hands");
            }
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
