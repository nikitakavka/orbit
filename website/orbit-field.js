(() => {
  const hero = document.querySelector('.hero');
  const canvas = document.querySelector('[data-orbit-field]');
  const logo = document.querySelector('.hero-logo');
  const copy = document.querySelector('.hero-copy');
  const hint = document.querySelector('[data-gravity-hint]');
  if (!hero || !canvas || !logo) return;

  const context = canvas.getContext('2d');
  if (!context) return;

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const finePointer = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
  const clamp = (value, minimum, maximum) => Math.max(minimum, Math.min(maximum, value));

  const MAX_BODIES = 7;
  const MIN_AMBIENT_SHIPS = 5;
  const MAX_AMBIENT_SHIPS = 7;
  const BODY_LIFETIME = 15;
  const TRAIL_LIFETIME = 1.35;
  const STEP = 1 / 120;
  const LAUNCH_SPEED_RATIO = .4;
  const MAX_BODY_SPEED = 460;

  let width = 1;
  let height = 1;
  let pixelRatio = 1;
  let gravity = {
    x: 0,
    y: 0,
    radius: 20,
    softening: 30,
    strength: 10_000_000
  };
  let maxPull = 120;
  let launchScale = 4.15;
  let aiming = null;
  let bodies = [];
  let impacts = [];
  let frame = null;
  let previousTime = 0;
  let hintTimer = null;
  let hintVisible = false;
  let hintHasShown = false;
  let hintEligible = false;

  function updateGeometry({ clear = false } = {}) {
    const heroBounds = hero.getBoundingClientRect();
    const logoBounds = logo.getBoundingClientRect();

    width = Math.max(1, heroBounds.width);
    height = Math.max(1, heroBounds.height);
    pixelRatio = Math.min(window.devicePixelRatio || 1, 2);

    canvas.width = Math.round(width * pixelRatio);
    canvas.height = Math.round(height * pixelRatio);

    gravity = {
      x: logoBounds.left - heroBounds.left + logoBounds.width / 2,
      y: logoBounds.top - heroBounds.top + logoBounds.height / 2,
      radius: clamp(logoBounds.width * (30 / 512), 13, 31),
      softening: clamp(logoBounds.width * .065, 24, 38),
      strength: clamp(width * height * 13, 5_000_000, 18_000_000)
    };

    maxPull = clamp(Math.min(width, height) * .15, 88, 135);
    launchScale = clamp(width / 350, 3.5, 4.25);

    if (clear) {
      aiming = null;
      bodies = [];
      impacts = [];
      hintEligible = false;
      if (!hintHasShown) hideHint();
      hero.classList.remove('is-aiming');
    }

    draw();
  }

  function localPoint(event) {
    const bounds = hero.getBoundingClientRect();
    return {
      x: event.clientX - bounds.left,
      y: event.clientY - bounds.top
    };
  }

  function isLaunchSurface(target) {
    if (!(target instanceof Element)) return false;
    return !target.closest('a, button, input, textarea, select, .hero-copy, .hero-logo');
  }

  function positionHint(point) {
    if (!hint) return;

    const hintWidth = hint.offsetWidth || 210;
    const hintHeight = hint.offsetHeight || 30;
    const gap = 16;
    let x = point.x + gap;
    let y = point.y + gap;

    if (x + hintWidth > width - 12) x = point.x - hintWidth - gap;
    if (y + hintHeight > height - 12) y = point.y - hintHeight - gap;

    hint.style.left = `${clamp(x, 12, Math.max(12, width - hintWidth - 12))}px`;
    hint.style.top = `${clamp(y, 12, Math.max(12, height - hintHeight - 12))}px`;
  }

  function hideHint() {
    if (hintTimer !== null) {
      clearTimeout(hintTimer);
      hintTimer = null;
    }

    hintVisible = false;
    hint?.classList.remove('is-visible');
  }

  function dismissHint() {
    hintHasShown = true;
    hintEligible = false;
    hideHint();
  }

  function considerHint(event) {
    if (!hint) return;

    if (aiming || !isLaunchSurface(event.target)) {
      hintEligible = false;
      if (!hintHasShown) hideHint();
      return;
    }

    hintEligible = true;
    positionHint(localPoint(event));

    if (hintVisible || hintHasShown || hintTimer !== null) return;

    hintTimer = window.setTimeout(() => {
      hintTimer = null;
      if (!hintEligible || aiming || hintHasShown) return;

      hintHasShown = true;
      hintVisible = true;
      hint.classList.add('is-visible');
    }, 1100);
  }

  function heldPoint(anchor, pointer) {
    const dx = pointer.x - anchor.x;
    const dy = pointer.y - anchor.y;
    const distance = Math.hypot(dx, dy);
    if (distance <= maxPull || distance === 0) return { x: pointer.x, y: pointer.y };

    const scale = maxPull / distance;
    return {
      x: anchor.x + dx * scale,
      y: anchor.y + dy * scale
    };
  }

  function launchVelocity(anchor, held) {
    return {
      x: (anchor.x - held.x) * launchScale * LAUNCH_SPEED_RATIO,
      y: (anchor.y - held.y) * launchScale * LAUNCH_SPEED_RATIO
    };
  }

  function accelerationAt(x, y, gravityScale = 1) {
    const dx = gravity.x - x;
    const dy = gravity.y - y;
    const softenedDistanceSquared = dx * dx + dy * dy + gravity.softening * gravity.softening;
    const inverseDistance = 1 / Math.sqrt(softenedDistanceSquared);
    const factor = gravity.strength * gravityScale
      * inverseDistance * inverseDistance * inverseDistance;

    return {
      x: dx * factor,
      y: dy * factor
    };
  }

  function distanceToGravity(x, y) {
    return Math.hypot(x - gravity.x, y - gravity.y);
  }

  function createBody(position, velocity, {
    kind = 'star',
    size = 1,
    gravityScale = 1,
    lifetime = BODY_LIFETIME
  } = {}) {
    const body = {
      x: position.x,
      y: position.y,
      vx: velocity.x,
      vy: velocity.y,
      age: 0,
      active: true,
      kind,
      size,
      gravityScale,
      lifetime,
      trailClock: 0,
      trail: [{ x: position.x, y: position.y, age: 0 }]
    };

    bodies.push(body);
    while (bodies.length > MAX_BODIES) bodies.shift();
    return body;
  }

  function pointOverCopy(x, y) {
    if (!copy) return false;

    const heroBounds = hero.getBoundingClientRect();
    const copyBounds = copy.getBoundingClientRect();
    const padding = 34;
    const left = copyBounds.left - heroBounds.left - padding;
    const top = copyBounds.top - heroBounds.top - padding;
    const right = copyBounds.right - heroBounds.left + padding;
    const bottom = copyBounds.bottom - heroBounds.top + padding;
    return x >= left && x <= right && y >= top && y <= bottom;
  }

  function randomAmbientPosition() {
    for (let attempt = 0; attempt < 40; attempt += 1) {
      const x = width * (.04 + Math.random() * .92);
      const y = height * (.1 + Math.random() * .8);
      const clearOfMass = distanceToGravity(x, y) > gravity.radius + 105;
      if (clearOfMass && !pointOverCopy(x, y)) return { x, y };
    }

    return {
      x: width * (.48 + Math.random() * .12),
      y: height * (.15 + Math.random() * .7)
    };
  }

  function randomAmbientMotion(position) {
    const dx = position.x - gravity.x;
    const dy = position.y - gravity.y;
    const distance = Math.max(1, Math.hypot(dx, dy));
    const gravityScale = .035 + Math.random() * .04;
    const softenedDistanceSquared = distance * distance
      + gravity.softening * gravity.softening;
    const localAcceleration = gravity.strength * gravityScale * distance
      / Math.pow(softenedDistanceSquared, 1.5);
    const orbitSpeed = Math.sqrt(localAcceleration * distance);
    const direction = Math.random() < .5 ? -1 : 1;
    const radialAngle = Math.atan2(dy, dx);
    const angle = radialAngle + direction * Math.PI / 2
      + (Math.random() - .5) * .22;
    const speed = clamp(orbitSpeed * (.84 + Math.random() * .28), 28, 78);

    return {
      gravityScale,
      velocity: {
        x: Math.cos(angle) * speed,
        y: Math.sin(angle) * speed
      }
    };
  }

  function seedAmbientShips() {
    if (reducedMotion) return;

    const count = MIN_AMBIENT_SHIPS
      + Math.floor(Math.random() * (MAX_AMBIENT_SHIPS - MIN_AMBIENT_SHIPS + 1));

    for (let index = 0; index < count; index += 1) {
      const position = randomAmbientPosition();
      const motion = randomAmbientMotion(position);
      createBody(position, motion.velocity, {
        kind: 'ship',
        size: .82 + Math.random() * .38,
        gravityScale: motion.gravityScale,
        lifetime: 45
      });
    }
  }

  function createImpact() {
    impacts.push({ age: 0, duration: .72 });
  }

  function updateBodies(delta) {
    bodies.forEach(body => {
      body.trail.forEach(point => { point.age += delta; });
      body.trail = body.trail.filter(point => point.age < TRAIL_LIFETIME);

      if (!body.active) return;

      body.age += delta;
      let remaining = delta;

      while (remaining > 0 && body.active) {
        const step = Math.min(STEP, remaining);
        const acceleration = accelerationAt(body.x, body.y, body.gravityScale);

        body.vx += acceleration.x * step;
        body.vy += acceleration.y * step;

        const speed = Math.hypot(body.vx, body.vy);
        if (speed > MAX_BODY_SPEED) {
          const speedScale = MAX_BODY_SPEED / speed;
          body.vx *= speedScale;
          body.vy *= speedScale;
        }

        body.x += body.vx * step;
        body.y += body.vy * step;
        body.trailClock += step;

        if (body.trailClock >= .028) {
          body.trailClock = 0;
          body.trail.push({ x: body.x, y: body.y, age: 0 });
          if (body.trail.length > 70) body.trail.shift();
        }

        if (distanceToGravity(body.x, body.y) <= gravity.radius) {
          body.active = false;
          createImpact();
        } else if (
          body.age > body.lifetime
          || body.x < -190
          || body.x > width + 190
          || body.y < -190
          || body.y > height + 190
        ) {
          body.active = false;
        }

        remaining -= step;
      }
    });

    bodies = bodies.filter(body => body.active || body.trail.length > 1);
  }

  function updateImpacts(delta) {
    impacts.forEach(impact => { impact.age += delta; });
    impacts = impacts.filter(impact => impact.age < impact.duration);
  }

  function previewTrajectory(anchor, held) {
    const velocity = launchVelocity(anchor, held);
    let x = held.x;
    let y = held.y;
    let vx = velocity.x;
    let vy = velocity.y;
    const points = [];
    const previewStep = .025;

    for (let index = 0; index < 132; index += 1) {
      const acceleration = accelerationAt(x, y);
      vx += acceleration.x * previewStep;
      vy += acceleration.y * previewStep;

      const speed = Math.hypot(vx, vy);
      if (speed > MAX_BODY_SPEED) {
        const speedScale = MAX_BODY_SPEED / speed;
        vx *= speedScale;
        vy *= speedScale;
      }

      x += vx * previewStep;
      y += vy * previewStep;

      if (index % 4 === 0) points.push({ x, y });

      if (
        distanceToGravity(x, y) <= gravity.radius
        || x < -80
        || x > width + 80
        || y < -80
        || y > height + 80
      ) break;
    }

    return points;
  }

  function drawTrail(body) {
    if (body.trail.length < 2) return;

    context.lineCap = 'round';
    context.lineWidth = .85;

    for (let index = 1; index < body.trail.length; index += 1) {
      const previous = body.trail[index - 1];
      const current = body.trail[index];
      const life = clamp(1 - current.age / TRAIL_LIFETIME, 0, 1);
      if (life <= 0) continue;

      context.beginPath();
      context.moveTo(previous.x, previous.y);
      context.lineTo(current.x, current.y);
      context.strokeStyle = `rgba(255, 99, 56, ${life * .26})`;
      context.stroke();
    }
  }

  function drawStar(x, y, vx, vy, alpha = 1, activeAim = false) {
    const speed = Math.hypot(vx, vy);
    const angle = speed > .01 ? Math.atan2(vy, vx) : 0;
    const size = activeAim ? 4.2 : 3.5;

    if (!activeAim && speed > 20) {
      const ux = vx / speed;
      const uy = vy / speed;
      const tailLength = clamp(speed * .026, 7, 19);
      const tail = context.createLinearGradient(
        x - ux * tailLength,
        y - uy * tailLength,
        x,
        y
      );
      tail.addColorStop(0, 'rgba(255, 99, 56, 0)');
      tail.addColorStop(1, `rgba(255, 99, 56, ${alpha * .45})`);

      context.beginPath();
      context.moveTo(x - ux * tailLength, y - uy * tailLength);
      context.lineTo(x, y);
      context.strokeStyle = tail;
      context.lineWidth = 1;
      context.stroke();
    }

    context.save();
    context.translate(x, y);
    context.rotate(angle);
    context.globalAlpha = alpha;
    context.shadowColor = 'rgba(255, 99, 56, .7)';
    context.shadowBlur = activeAim ? 9 : 6;
    context.beginPath();
    context.moveTo(size, 0);
    context.lineTo(size * .28, size * .3);
    context.lineTo(0, size);
    context.lineTo(-size * .28, size * .3);
    context.lineTo(-size, 0);
    context.lineTo(-size * .28, -size * .3);
    context.lineTo(0, -size);
    context.lineTo(size * .28, -size * .3);
    context.closePath();
    context.fillStyle = activeAim ? '#ff6338' : '#f1efe9';
    context.fill();
    context.restore();
  }

  function drawShip(x, y, vx, vy, alpha = 1, sizeScale = 1) {
    const angle = Math.atan2(vy, vx);
    const size = 5.2 * sizeScale;

    context.save();
    context.translate(x, y);
    context.rotate(angle);
    context.globalAlpha = alpha * .82;
    context.shadowColor = 'rgba(255, 99, 56, .58)';
    context.shadowBlur = 5;

    context.beginPath();
    context.moveTo(size, 0);
    context.lineTo(-size * .58, -size * .42);
    context.lineTo(-size * .27, 0);
    context.lineTo(-size * .58, size * .42);
    context.closePath();
    context.fillStyle = '#f1efe9';
    context.fill();

    context.beginPath();
    context.arc(-size * .5, 0, Math.max(1, size * .18), 0, Math.PI * 2);
    context.fillStyle = '#ff6338';
    context.fill();
    context.restore();
  }

  function drawImpacts() {
    impacts.forEach(impact => {
      const progress = clamp(impact.age / impact.duration, 0, 1);
      const eased = 1 - Math.pow(1 - progress, 3);
      const alpha = (1 - progress) * .48;

      context.beginPath();
      context.arc(gravity.x, gravity.y, gravity.radius + eased * 35, 0, Math.PI * 2);
      context.strokeStyle = `rgba(255, 99, 56, ${alpha})`;
      context.lineWidth = 1;
      context.stroke();

      const glowRadius = gravity.radius * (1.1 + eased * .75);
      const glow = context.createRadialGradient(
        gravity.x,
        gravity.y,
        0,
        gravity.x,
        gravity.y,
        glowRadius
      );
      glow.addColorStop(0, `rgba(255, 99, 56, ${(1 - progress) * .18})`);
      glow.addColorStop(1, 'rgba(255, 99, 56, 0)');
      context.fillStyle = glow;
      context.beginPath();
      context.arc(gravity.x, gravity.y, glowRadius, 0, Math.PI * 2);
      context.fill();
    });
  }

  function drawAim() {
    if (!aiming) return;

    const held = heldPoint(aiming.anchor, aiming.pointer);
    const pullDistance = Math.hypot(held.x - aiming.anchor.x, held.y - aiming.anchor.y);
    const velocity = launchVelocity(aiming.anchor, held);

    context.beginPath();
    context.moveTo(held.x, held.y);
    context.lineTo(aiming.anchor.x, aiming.anchor.y);
    context.strokeStyle = 'rgba(241, 239, 233, .18)';
    context.lineWidth = .8;
    context.stroke();

    context.beginPath();
    context.arc(aiming.anchor.x, aiming.anchor.y, 4.5, 0, Math.PI * 2);
    context.strokeStyle = 'rgba(255, 99, 56, .65)';
    context.lineWidth = 1;
    context.stroke();

    if (pullDistance >= 5) {
      const points = previewTrajectory(aiming.anchor, held);
      points.forEach((point, index) => {
        const progress = index / Math.max(1, points.length - 1);
        const alpha = .48 * (1 - progress * .78);
        const radius = 1.3 - progress * .45;
        context.beginPath();
        context.arc(point.x, point.y, radius, 0, Math.PI * 2);
        context.fillStyle = `rgba(255, 99, 56, ${alpha})`;
        context.fill();
      });
    }

    drawStar(held.x, held.y, velocity.x, velocity.y, 1, true);
  }

  function draw() {
    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    context.clearRect(0, 0, width, height);

    drawImpacts();
    bodies.forEach(drawTrail);
    bodies.forEach(body => {
      if (!body.active) return;
      const fade = body.age > body.lifetime - 2
        ? clamp((body.lifetime - body.age) / 2, 0, 1)
        : 1;
      if (body.kind === 'ship') {
        drawShip(body.x, body.y, body.vx, body.vy, fade, body.size);
      } else {
        drawStar(body.x, body.y, body.vx, body.vy, fade);
      }
    });
    drawAim();
  }

  function animate(time) {
    const elapsed = previousTime ? Math.min(40, time - previousTime) : 16.67;
    previousTime = time;
    const delta = elapsed / 1000;

    updateBodies(delta);
    updateImpacts(delta);
    draw();

    if (aiming || bodies.length || impacts.length) {
      frame = requestAnimationFrame(animate);
    } else {
      frame = null;
      previousTime = 0;
      draw();
    }
  }

  function requestAnimation() {
    if (frame === null) frame = requestAnimationFrame(animate);
  }

  function finishAim(event, { cancel = false } = {}) {
    if (!aiming || event.pointerId !== aiming.pointerId) return;

    const completedAim = aiming;
    const held = heldPoint(completedAim.anchor, completedAim.pointer);
    const pullDistance = Math.hypot(held.x - completedAim.anchor.x, held.y - completedAim.anchor.y);
    aiming = null;

    if (!cancel && pullDistance >= 8) {
      createBody(held, launchVelocity(completedAim.anchor, held));
      dismissHint();
    }

    if (hero.hasPointerCapture?.(event.pointerId)) {
      hero.releasePointerCapture(event.pointerId);
    }

    hero.classList.remove('is-aiming');
    requestAnimation();
  }

  function bindInput() {
    hero.addEventListener('pointerenter', considerHint);

    hero.addEventListener('pointerleave', () => {
      if (aiming) return;
      hintEligible = false;
      if (!hintHasShown) hideHint();
    });

    hero.addEventListener('pointerdown', event => {
      if (event.button !== 0 || aiming || !isLaunchSurface(event.target)) return;

      const anchor = localPoint(event);
      aiming = {
        pointerId: event.pointerId,
        anchor,
        pointer: anchor
      };

      hero.setPointerCapture?.(event.pointerId);
      hero.classList.add('is-aiming');
      event.preventDefault();
      requestAnimation();
    });

    hero.addEventListener('pointermove', event => {
      if (!aiming) {
        considerHint(event);
        return;
      }
      if (event.pointerId !== aiming.pointerId) return;

      aiming.pointer = localPoint(event);
      event.preventDefault();
      requestAnimation();
    });

    hero.addEventListener('pointerup', event => finishAim(event));
    hero.addEventListener('pointercancel', event => finishAim(event, { cancel: true }));
    hero.addEventListener('lostpointercapture', event => {
      if (aiming && event.pointerId === aiming.pointerId) finishAim(event, { cancel: true });
    });

    window.addEventListener('blur', () => {
      hintEligible = false;
      if (!hintHasShown) hideHint();
      if (!aiming) return;
      aiming = null;
      hero.classList.remove('is-aiming');
      requestAnimation();
    });

    window.addEventListener('keydown', event => {
      if (event.key !== 'Escape' || !aiming) return;
      aiming = null;
      hero.classList.remove('is-aiming');
      requestAnimation();
    });
  }

  function resetField() {
    updateGeometry({ clear: true });
    seedAmbientShips();
    requestAnimation();
  }

  const resizeObserver = new ResizeObserver(resetField);
  resizeObserver.observe(hero);
  resizeObserver.observe(logo);
  resetField();

  if (finePointer && !reducedMotion) bindInput();
})();
