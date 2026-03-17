import { useRef, useEffect } from 'react';
import { useInView } from 'framer-motion';

interface ParticleFieldProps {
  density?: number;
  colors?: string[];
  driftSpeed?: number;
  style?: React.CSSProperties;
}

interface Particle {
  x: number;
  y: number;
  r: number;
  vx: number;
  vy: number;
  color: string;
  alpha: number;
}

export function ParticleField({
  density = 60,
  colors = ['#7c3aed', '#a855f7', '#06b6d4', '#f8f5ff'],
  driftSpeed = 0.3,
  style,
}: ParticleFieldProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  const isInView = useInView(containerRef, { margin: '100px' });
  const particlesRef = useRef<Particle[]>([]);
  const animRef = useRef<number>(0);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const dpr = Math.min(window.devicePixelRatio, 1.5);

    const resize = () => {
      const rect = canvas.parentElement!.getBoundingClientRect();
      canvas.width = rect.width * dpr;
      canvas.height = rect.height * dpr;
      canvas.style.width = `${rect.width}px`;
      canvas.style.height = `${rect.height}px`;
      ctx.scale(dpr, dpr);
    };

    resize();

    const w = () => canvas.width / Math.min(window.devicePixelRatio, 1.5);
    const h = () => canvas.height / Math.min(window.devicePixelRatio, 1.5);

    particlesRef.current = Array.from({ length: density }, () => ({
      x: Math.random() * w(),
      y: Math.random() * h(),
      r: Math.random() * 1.8 + 0.4,
      vx: (Math.random() - 0.5) * driftSpeed,
      vy: (Math.random() - 0.5) * driftSpeed,
      color: colors[Math.floor(Math.random() * colors.length)],
      alpha: Math.random() * 0.6 + 0.2,
    }));

    window.addEventListener('resize', resize);
    return () => window.removeEventListener('resize', resize);
  }, [density, colors, driftSpeed]);

  useEffect(() => {
    if (!isInView) {
      cancelAnimationFrame(animRef.current);
      return;
    }

    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const dpr = Math.min(window.devicePixelRatio, 1.5);
    const w = () => canvas.width / dpr;
    const h = () => canvas.height / dpr;

    const animate = () => {
      ctx.clearRect(0, 0, w(), h());
      for (const p of particlesRef.current) {
        p.x += p.vx;
        p.y += p.vy;
        if (p.x < 0) p.x = w();
        if (p.x > w()) p.x = 0;
        if (p.y < 0) p.y = h();
        if (p.y > h()) p.y = 0;

        ctx.beginPath();
        ctx.arc(p.x, p.y, p.r, 0, Math.PI * 2);
        ctx.fillStyle = p.color;
        ctx.globalAlpha = p.alpha;
        ctx.fill();
      }
      ctx.globalAlpha = 1;
      animRef.current = requestAnimationFrame(animate);
    };

    animate();
    return () => cancelAnimationFrame(animRef.current);
  }, [isInView]);

  return (
    <div
      ref={containerRef}
      style={{
        position: 'absolute',
        inset: 0,
        pointerEvents: 'none',
        zIndex: 0,
        ...style,
      }}
    >
      <canvas ref={canvasRef} style={{ width: '100%', height: '100%' }} />
    </div>
  );
}
