// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IRiscZeroVerifier} from "risc0/IRiscZeroVerifier.sol";

contract ZkBlackjack {
  /// IMMUTABLES ///
  
  IRiscZeroVerifier public immutable verifier;

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
    bytes32 playerPublicKey;

    /// Sum of all deltas of the player's hands
    /// (player won - player bet) for all hands
    uint256 gameNetWin; 

    uint256[] bets;

    /// Block number when the game was created. Used for timeout to prevent dealer from stalling
    uint256 gameStartBlock;
  }

  /// Deserialization of RISC0 journal
  struct Output {
      bytes32 dealerCommitment;
      bytes32[] playerCommitments;
      bytes32[2][] playerPubkeys;
      uint256[] payouts;
      uint8[][] doubleHands;
      uint8[][] splitHands;
  }

  /// EVENTS ///

  event GameStarted(address indexed player, uint256 indexed gameId, address indexed dealer);
  event GameResult(
    address indexed player,
    uint256 indexed gameId,
    address indexed dealer,
    uint256 gameNetWin
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
      require(games[_gameIds[i]].dealer == msg.sender, NotADealerOfThisGame());
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
    address payable _dealer,
    uint256 _bet,
    bytes32 _playerCommitment,
    bytes32 _playerPublicKey
  ) external payable {
       
  }

  /// Player calls this function to double the bet on ONE OF his hands
  /// If split is not possible, the function does nothing and player loses the bet 
  /// Reverts if dealer doesn't have enough money to match the bet
  function double(uint256 _gameId, uint256 _handIndex) external payable {
  
  }

  /// Player call this function to split the hand
  /// If split is not possible, the function does nothing and player loses the bet 
  /// Reverts if dealer doesn't have enough money to match the bet
  function split(uint256 _gameId, uint256 _handIndex) external payable {
  
  }

  /// DEALER FUNCTIONS ///

  function registerDealer(
    uint256 _minBet,
    uint256 _maxBet,
    uint256 _fee,
    uint256 _timeoutBlocks,
    bytes32 _commitment
  ) external allowedToRegisterDealer {
    require(dealers[msg.sender].addr == address(0), DealerAlreadyRegistered());
  
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

  function setBetLimits(uint256 _minBet, uint256 _maxBet) external onlyOfflineDealer {
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
    require(dealers[msg.sender].balance >= _amount, "Not enough balance");
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
    require(!game.finished, "Game is already finished");
    require(game.gameNetWin == 0, "Winnings have already been transferred");
    game.gameNetWin = _payout;
    dealers[msg.sender].lockedBalance -= _payout;
    dealers[msg.sender].balance -= _payout;
    game.player.transfer(_payout);
  }

  /// Prove several games at once using a single RISC0 proof
  /// User winnings have to be transferred before calling this function
  function proveGames(
    uint256[] calldata _gameIds,
    bytes memory _proof
  ) external onlyDealerOfTheGames(_gameIds) {
  
  }

  /// Can be called by the player if the dealer is not submitting proof for a long time
  /// The player receives 2.5x of the total bet they put in from dealer's balance
  /// (as if they had blackjack in all hands)
  /// And dealer is banned so that they can't start new games
  function reclaimGame(
    uint256 _gameId
  ) external {
    Game storage game = games[_gameId];
    require(!game.finished, "Game is already finished");
    require(game.player == msg.sender, "Player is not the player of the game");
    require(block.number > game.gameStartBlock + dealers[game.dealer].timeoutBlocks, "Timeout not reached");
    
  }
}
