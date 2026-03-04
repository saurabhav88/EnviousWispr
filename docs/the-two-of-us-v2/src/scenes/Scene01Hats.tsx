import { motion } from 'framer-motion';
import { Scene } from '../components/Scene';
import { Caption } from '../components/Caption';
import { ParticleField } from '../components/ParticleField';
import styles from './Scene01Hats.module.css';

const hats = [
  {
    id: 'beret',
    label: 'Designer',
    delay: 0,
    x: '-55%',
    icon: (
      <svg viewBox="0 0 60 40" fill="none" xmlns="http://www.w3.org/2000/svg" width="52" height="36">
        <ellipse cx="30" cy="22" rx="28" ry="14" fill="rgba(180,120,255,0.85)" />
        <ellipse cx="30" cy="22" rx="20" ry="10" fill="rgba(140,70,240,0.7)" />
        <circle cx="30" cy="10" r="6" fill="rgba(200,150,255,0.9)" />
        <ellipse cx="30" cy="36" rx="28" ry="4" fill="rgba(100,50,180,0.4)" />
      </svg>
    ),
    color: '#b47fff',
  },
  {
    id: 'hardhat',
    label: 'Engineer',
    delay: 0.12,
    x: '-25%',
    icon: (
      <svg viewBox="0 0 60 48" fill="none" xmlns="http://www.w3.org/2000/svg" width="52" height="42">
        <path d="M4 34 Q30 8 56 34" fill="rgba(255,200,60,0.85)" />
        <rect x="4" y="30" width="52" height="10" rx="5" fill="rgba(255,180,20,0.9)" />
        <rect x="22" y="10" width="16" height="22" rx="2" fill="rgba(255,220,100,0.7)" />
        <rect x="0" y="34" width="60" height="6" rx="3" fill="rgba(200,140,0,0.6)" />
      </svg>
    ),
    color: '#ffc83c',
  },
  {
    id: 'headphones',
    label: 'Support',
    delay: 0.24,
    x: '0%',
    icon: (
      <svg viewBox="0 0 60 50" fill="none" xmlns="http://www.w3.org/2000/svg" width="52" height="44">
        <path d="M8 28 Q8 6 30 6 Q52 6 52 28" stroke="rgba(100,220,255,0.8)" strokeWidth="5" fill="none" strokeLinecap="round" />
        <rect x="2" y="24" width="14" height="22" rx="7" fill="rgba(0,180,220,0.8)" />
        <rect x="44" y="24" width="14" height="22" rx="7" fill="rgba(0,180,220,0.8)" />
        <rect x="5" y="26" width="8" height="18" rx="4" fill="rgba(0,220,255,0.5)" />
        <rect x="47" y="26" width="8" height="18" rx="4" fill="rgba(0,220,255,0.5)" />
      </svg>
    ),
    color: '#00ccff',
  },
  {
    id: 'clipboard',
    label: 'Manager',
    delay: 0.36,
    x: '25%',
    icon: (
      <svg viewBox="0 0 52 60" fill="none" xmlns="http://www.w3.org/2000/svg" width="44" height="52">
        <rect x="4" y="10" width="44" height="48" rx="5" fill="rgba(100,200,150,0.75)" />
        <rect x="18" y="2" width="16" height="14" rx="4" fill="rgba(60,160,110,0.9)" />
        <rect x="10" y="22" width="32" height="3" rx="1.5" fill="rgba(255,255,255,0.5)" />
        <rect x="10" y="30" width="24" height="3" rx="1.5" fill="rgba(255,255,255,0.4)" />
        <rect x="10" y="38" width="28" height="3" rx="1.5" fill="rgba(255,255,255,0.4)" />
        <rect x="10" y="46" width="18" height="3" rx="1.5" fill="rgba(255,255,255,0.3)" />
      </svg>
    ),
    color: '#64c896',
  },
  {
    id: 'tie',
    label: 'Marketer',
    delay: 0.48,
    x: '55%',
    icon: (
      <svg viewBox="0 0 36 64" fill="none" xmlns="http://www.w3.org/2000/svg" width="32" height="56">
        <path d="M18 4 L28 24 L18 20 L8 24 Z" fill="rgba(255,100,140,0.85)" />
        <path d="M8 24 L18 20 L28 24 L22 58 L14 58 Z" fill="rgba(220,60,110,0.9)" />
        <path d="M14 58 L22 58 L20 64 L16 64 Z" fill="rgba(255,80,130,0.75)" />
      </svg>
    ),
    color: '#ff649a',
  },
];

function FloatingHat({ hat, index }: { hat: (typeof hats)[0]; index: number }) {
  return (
    <motion.div
      className={styles.hat}
      style={{ left: `calc(50% + ${hat.x})` } as React.CSSProperties}
      initial={{ y: 60, rotate: index % 2 === 0 ? -12 : 12 }}
      animate={{
        y: [0, -12, 0],
        rotate: [index % 2 === 0 ? -6 : 6, index % 2 === 0 ? 6 : -6, index % 2 === 0 ? -6 : 6],
      }}
      transition={{
        y: { duration: 3.2 + index * 0.4, repeat: Infinity, ease: 'easeInOut', delay: hat.delay },
        rotate: { duration: 4 + index * 0.3, repeat: Infinity, ease: 'easeInOut', delay: hat.delay + 0.5 },
      }}
    >
      <div className={styles.hatGlow} style={{ '--hat-color': hat.color } as React.CSSProperties} />
      <div className={styles.hatIcon}>{hat.icon}</div>
      <span className={styles.hatLabel} style={{ color: hat.color }}>
        {hat.label}
      </span>
    </motion.div>
  );
}

export function Scene01Hats() {
  return (
    <Scene
      id="scene-01-hats"
      minHeight="100vh"
      background="radial-gradient(ellipse at 50% 70%, rgba(60,20,80,0.6), #0f0a1a)"
     
    >
      <ParticleField
        density={55}
        colors={['#7c3aed', '#a855f7', '#4c1d95', '#c4b5fd', '#1e1035']}
        driftSpeed={0.2}
      />

      <motion.img
        src="/scenes/scene-01-hats.png"
        alt=""
        className={styles.bgIllustration}
        loading="lazy"
        initial={{ opacity: 0 }}
        whileInView={{ opacity: 0.6 }}
        viewport={{ once: true }}
        transition={{ duration: 1.5 }}
      />

      <div className={styles.wrapper}>
        <div className={styles.hatsRow}>
          {hats.map((hat, i) => (
            <FloatingHat key={hat.id} hat={hat} index={i} />
          ))}
        </div>

        <motion.div
          className={styles.captionArea}
          initial={{ y: 20 }}
          whileInView={{ y: 0 }}
          viewport={{ once: true, margin: '-10%' }}
          transition={{ duration: 0.7, delay: 1.0 }}
        >
          <Caption>Building something alone means wearing every hat.</Caption>
        </motion.div>

        <div className={styles.ambientGlow} />
      </div>
    </Scene>
  );
}
