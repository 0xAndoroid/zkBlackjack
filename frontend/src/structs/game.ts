export class GameState {
  dealer_hand: Card[];
  player_hands: Card[][];
  active_hands: boolean[];
  bets: number[];
  player_seed: Uint8Array;
  player_pubkey: Uint8Array;

  hand_id: number;
  
  constructor() {
    this.dealer_hand = [];
    this.player_hands = [];
    
    this.bets = [];
    // gen random seed
    this.player_seed = new Uint8Array(16);
    this.player_seed = crypto.getRandomValues(this.player_seed);
    this.active_hands = [];
    this.player_pubkey = new Uint8Array(32);
    this.player_pubkey = crypto.getRandomValues(this.player_pubkey);
    this.hand_id = 0;
  }

  can_do() : [boolean, boolean, boolean, boolean] {
    if (!this.player_hands[this.hand_id]) return [false, false, false, false];
    // return [can_hit, can_stand, can_double, can_split]
    const player_hand = this.player_hands[this.hand_id];
    const can_hit = this.sum_min(player_hand) < 21 && this.active_hands[this.hand_id];
    const can_stand = this.active_hands[this.hand_id];
    const can_double = player_hand.length == 2 && this.active_hands[this.hand_id];
    const can_split = player_hand.length == 2 && player_hand[0].rank == player_hand[1].rank && this.active_hands[this.hand_id];
    return [can_hit, can_stand, can_double, can_split];
  }

  update(dealer: Card[], player: Card[][], active: boolean[], bets: number[], active_hand: number) {
    this.dealer_hand = dealer;
    this.player_hands = player;
    this.active_hands = active;
    this.bets = bets;
    this.hand_id = active_hand;
  }

  sum_min(hand: Card[]) : number {
    if (!hand) return 0;
    let sum = 0;
    if (hand.length == 0) return 0;
    for (const card of hand) {
      sum += card.value;
    }
    return sum;
  }
  
  sum_hand(hand: Card[]) : number {
    if (!hand) return 0;
    let sum = 0;
    let has_ace = false;
    for (const card of hand) {
      if (card.value == 1) {
        has_ace = true;
      }
      sum += card.value;
    }
    if (has_ace && sum + 10 <= 21) {
      sum += 10;
    }
    return sum;
  }

  async commitment() {
    return await sha256Uint8Array(this.player_seed);
  }
}

async function sha256Uint8Array(input: Uint8Array) {
    // Compute the SHA-256 hash of the input array
    const hashBuffer = await crypto.subtle.digest('SHA-256', input);

    // Convert the ArrayBuffer to a Uint8Array
    const hashArray = new Uint8Array(hashBuffer);

    return hashArray;
}

export class Card {
  suit: 'hearts' | 'diamonds' | 'clubs' | 'spades';
  rank: number;
  value: number;

  constructor(suit: 'hearts' | 'diamonds' | 'clubs' | 'spades', rank: number) {
    this.suit = suit;
    this.rank = rank;
    this.value = Math.min(rank, 10);
  }
  
}
