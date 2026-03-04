import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import { RainbowText } from '../components/RainbowText';
import styles from './Scene04Office.module.css';

const titleVariants = {
  hidden: { opacity: 0, y: -30 },
  visible: {
    opacity: 1,
    y: 0,
    transition: { duration: 0.7, ease: 'easeOut' },
  },
};

export function Scene04Office() {
  const ref = useRef<HTMLDivElement>(null);
  const isInView = useInView(ref, { once: true, margin: '-10%' });

  return (
    <Scene id="scene-04" minHeight="110vh" background="radial-gradient(ellipse at 50% 50%, rgba(60,20,80,0.4), #0f0a1a)" parallaxIntensity={0.12}>
      <motion.img src="/scenes/scene-04-office.png" alt="" className={styles.bgIllustration} loading="lazy"
        initial={{ opacity: 0 }} whileInView={{ opacity: 0.55 }} viewport={{ once: true }} transition={{ duration: 1.5 }} />
      <div className={styles.wrapper} ref={ref}>
        <motion.h2 className={styles.title} variants={titleVariants} initial="hidden" animate={isInView ? 'visible' : 'hidden'}>
          <RainbowText>The Office Fills Up</RainbowText>
        </motion.h2>
        <Caption>
          One conversation became a team.{'\n'}The same mind, wearing every hat — by choice this time.
        </Caption>
      </div>
    </Scene>
  );
}
