import { ManhwaContainer } from './components/ManhwaContainer';
import { Scene01Hats } from './scenes/Scene01Hats';
import { Scene02Canvas } from './scenes/Scene02Canvas';
import { Scene03Conversation } from './scenes/Scene03Conversation';
import { Scene04Office } from './scenes/Scene04Office';
import { Scene05Building } from './scenes/Scene05Building';
import { Scene06Product } from './scenes/Scene06Product';
import { Scene07Explainer } from './scenes/Scene07Explainer';
import { Scene07People } from './scenes/Scene07People';
import { Scene08Reveal } from './scenes/Scene08Reveal';
import { Scene10Horizon } from './scenes/Scene10Horizon';

export function App() {
  return (
    <ManhwaContainer>
      <Scene02Canvas />
      <Scene01Hats />
      <Scene03Conversation />
      <Scene04Office />
      <Scene05Building />
      <Scene06Product />
      <Scene07Explainer />
      <Scene07People />
      <Scene08Reveal />
      <Scene10Horizon />
    </ManhwaContainer>
  );
}
