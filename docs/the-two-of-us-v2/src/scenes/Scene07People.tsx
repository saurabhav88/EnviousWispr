import { motion, useInView } from 'framer-motion';
import { useRef } from 'react';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import styles from './Scene07People.module.css';

const vignettes = [
  { persona: 'The Student', accent: '#e6c200',
    before: '"prof said um the mitochondria thing is uh really important for like the cell"',
    after: '"The mitochondria plays a critical role in cellular energy production."' },
  { persona: 'The Writer', accent: '#d45a90',
    before: '"she walked slowly toward the door and it was kinda scary and dark outside"',
    after: '"She approached the door, the darkness beyond pressing against the glass."' },
  { persona: 'The Parent', accent: '#00fa9a',
    before: '"hey sorry to bother can we reschedule the um thing for next week maybe thursday"',
    after: '"Hi, would it be possible to reschedule to Thursday of next week?"' },
  { persona: 'The Executive', accent: '#1e90ff',
    before: '"so q3 was good revenue up but costs also went up need to address that in report"',
    after: '"Q3 revenue increased, though rising costs warrant attention in the quarterly report."' },
];

export function Scene07People() {
  const headlineRef = useRef<HTMLDivElement>(null);
  const isHeadlineInView = useInView(headlineRef, { once: true, margin: '-5%' });

  return (
    <Scene id="scene-07" minHeight="120vh" background="linear-gradient(180deg, #1a0a1a 0%, #0f0a1a 100%)" parallaxIntensity={12}>
      <motion.img src="/scenes/scene-07-people.png" alt="" className={styles.bgIllustration} loading="lazy"
        initial={{ opacity: 0 }} whileInView={{ opacity: 0.5 }} viewport={{ once: true }} transition={{ duration: 1.5 }} />
      <div className={styles.wrapper}>
        <motion.div ref={headlineRef} className={styles.headline}
          initial={{ opacity: 0, y: 24 }} animate={isHeadlineInView ? { opacity: 1, y: 0 } : {}}
          transition={{ duration: 0.8, ease: 'easeOut' }}>
          <span className={styles.headlineWhite}>Built for real people.</span>{' '}
          <span className={styles.headlineGold}>Used by real people.</span>
        </motion.div>

        <div className={styles.pairs}>
          {vignettes.map((v, i) => (
            <motion.div key={v.persona} className={styles.pair}
              style={{ '--accent': v.accent } as React.CSSProperties}
              initial={{ opacity: 0, y: 20 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: '-5%' }}
              transition={{ duration: 0.5, delay: i * 0.12 }}>
              <span className={styles.persona}>{v.persona}</span>
              <div className={styles.textRow}>
                <span className={styles.tag} data-type="raw">raw</span>
                <p className={styles.beforeText}>{v.before}</p>
              </div>
              <div className={styles.textRow}>
                <span className={styles.tag} data-type="polished">polished</span>
                <p className={styles.afterText}>{v.after}</p>
              </div>
            </motion.div>
          ))}
        </div>

        <Caption>Every word counts. Every moment matters. Yours too.</Caption>
      </div>
    </Scene>
  );
}
