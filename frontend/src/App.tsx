import { useEffect, useState } from "react";
import "@rainbow-me/rainbowkit/styles.css";
import {
  ConnectButton,
  getDefaultWallets,
  RainbowKitProvider,
} from "@rainbow-me/rainbowkit";
import { configureChains, createConfig, useAccount, WagmiConfig } from "wagmi";
import { sepolia } from "wagmi/chains";
import { publicProvider } from "wagmi/providers/public";
import { Card, Hand } from "./components/Card";
import { GameState } from "./structs/game";
import { Card as CardStruct } from "./structs/game";
import { ethers } from "ethers";

const { chains, publicClient } = configureChains(
  [sepolia],
  [publicProvider()]
);

const { connectors } = getDefaultWallets({
  appName: "zkBlackjack",
  projectId: "63af36926a9ad005a89d885e7f6a5924",
  chains,
});

const wagmiConfig = createConfig({
  autoConnect: true,
  connectors,
  publicClient,
});

function App() {
  const { address, connector, isConnecting, isDisconnected } = useAccount();

  const [game, setGame] = useState<GameState>(new GameState());
  const [canHit, canStand, canDouble, canSplit] = game.can_do();

  async function stand() {
    fetch("http://localhost:3000/action", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        action: "stand",
        address: address,
      }),
    });
  }

  useEffect(() => {
    setGame((game) => {
      game.dealer_hand = [
        new CardStruct("hearts", 1),
        new CardStruct("hearts", 2),
      ];
      game.player_hands = [
        [new CardStruct("spades", 4), new CardStruct("hearts", 4)],
        [new CardStruct("clubs", 5), new CardStruct("diamonds", 6)],
      ];
      game.active_hands = [true, false];
      return game;
    })
  }, []);

  if (isConnecting) {
    return (
      <WagmiConfig config={wagmiConfig}>
        <RainbowKitProvider chains={chains}>
          <div className="flex justify-end my-5 mx-10 w-auto">
            <ConnectButton />
          </div>
          <h1 className="text-3xl text-center animate-pulse">
            Connecting to your wallet...
          </h1>
        </RainbowKitProvider>
      </WagmiConfig>
    );
  }
  if (isDisconnected) {
    return (
      <WagmiConfig config={wagmiConfig}>
        <RainbowKitProvider chains={chains}>
          <div className="flex justify-end my-5 mx-10 w-auto">
            <ConnectButton />
          </div>
          <h1 className="text-3xl text-center animate-pulse">
            Please connect to your wallet to continue.
          </h1>
        </RainbowKitProvider>
      </WagmiConfig>
    );
  }
  return (
    <WagmiConfig config={wagmiConfig}>
      <RainbowKitProvider chains={chains}>
        <div className="flex justify-between my-5 mx-10 w-auto">
          <img src="/logo.png" className="my-auto h-14 w-14" />
          <div className="flex justify-end w-auto h-auto">
            <ConnectButton />
          </div>
        </div>
        <div className="flex justify-around flex-row">
          <Hand cards={game.dealer_hand} active={false} />
        </div>
        <div className="flex justify-around flex-row my-16">
          {game.player_hands.map((p, i) =>
            <Hand cards={p} active={game.active_hands[i]} />
          )}
        </div>
        <div className="flex justify-around flex-row">
          <button className={`bg-green-500 hover:bg-green-700 text-white font-bold py-2 px-4 rounded${canHit ? "" : " invisible"}`}>
            Hit
          </button>
          <button className={`bg-red-500 hover:bg-red-700 text-white font-bold py-2 px-4 rounded${canStand ? "" : " invisible"}`}>
            Stand
          </button>
          <button className={`bg-blue-500 hover:bg-blue-700 text-white font-bold py-2 px-4 rounded${canDouble ? "" : " invisible"}`}>
            Double
          </button>
          <button className={`bg-yellow-500 hover:bg-yellow-700 text-white font-bold py-2 px-4 rounded${canSplit ? "" : " invisible"}`}>
            Split
          </button>
        </div>
      </RainbowKitProvider>
    </WagmiConfig>
  );
}

export default App;
