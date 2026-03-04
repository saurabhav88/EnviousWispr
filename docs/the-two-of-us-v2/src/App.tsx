import { ManhwaContainer } from './components/ManhwaContainer';
import { Scene01Hats } from './scenes/Scene01Hats';
import { Scene02Canvas } from './scenes/Scene02Canvas';
import { Scene03Conversation } from './scenes/Scene03Conversation';
import { Scene04Office } from './scenes/Scene04Office';
import { Scene05Building } from './scenes/Scene05Building';
import { Scene06Product } from './scenes/Scene06Product';
import { Scene07People } from './scenes/Scene07People';
import { Scene08Reveal } from './scenes/Scene08Reveal';
import { Scene09Numbers } from './scenes/Scene09Numbers';
import { Scene10Horizon } from './scenes/Scene10Horizon';

export function App() {
  return (
    <ManhwaContainer>
      <Scene01Hats />
      <Scene02Canvas />
      <Scene03Conversation />
      <Scene04Office />
      <Scene05Building />
      <Scene06Product />
      <Scene07People />
      <Scene08Reveal />
      <Scene09Numbers />
      <Scene10Horizon />
    </ManhwaContainer>
  );
}
