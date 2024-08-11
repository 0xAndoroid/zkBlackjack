import { Card as CardStruct } from '../structs/game';

interface CardProps {
  rank: number;
  suit: 'hearts' | 'diamonds' | 'clubs' | 'spades';
}

export function Hand({ cards, active } : { cards: CardStruct[], active: boolean }) {
  return (
    <div className={`flex flex-row flex-shrink-0 flex-wrap${active ? " shadow-black shadow-lg" : ""}`}>
      {cards.map((card) => <Card suit={card.suit} rank={card.rank} />)}
    </div>
  );
}

export function Card({ rank, suit } : CardProps) {
  return (
    <img
      src={get_file_name(rank, suit)}
      alt={`${rank} of ${suit}`}
      className="h-52"
    />
  );
}

function get_file_name(value: number, suit: 'hearts' | 'diamonds' | 'clubs' | 'spades') {
  return `${suit}/Card${value == 1 ? "" : "-" + (value - 1).toString()}.svg`;
}

