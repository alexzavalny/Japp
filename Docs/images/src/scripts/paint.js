// Draws a picture on Paint's canvas for the README screenshot.
const c = document.getElementById('image'); const x = c.getContext('2d');
const W = c.width, H = c.height;
x.imageSmoothingEnabled = false;
x.fillStyle = '#80FFFF'; x.fillRect(0, 0, W, H);
x.fillStyle = '#00FF80'; x.beginPath(); x.ellipse(W * 0.28, H * 0.95, W * 0.55, H * 0.42, 0, 0, Math.PI * 2); x.fill();
x.fillStyle = '#008000'; x.beginPath(); x.ellipse(W * 0.85, H * 1.02, W * 0.45, H * 0.4, 0, 0, Math.PI * 2); x.fill();
x.fillStyle = '#FFFF00'; x.beginPath(); x.arc(W * 0.82, H * 0.18, 44, 0, Math.PI * 2); x.fill();
x.strokeStyle = '#FFFF00'; x.lineWidth = 6;
for (let i = 0; i < 12; i++) { const a = i * Math.PI / 6; x.beginPath(); x.moveTo(W*.82 + Math.cos(a)*58, H*.18 + Math.sin(a)*58); x.lineTo(W*.82 + Math.cos(a)*80, H*.18 + Math.sin(a)*80); x.stroke(); }
// house
x.fillStyle = '#FFFF80'; x.fillRect(150, 230, 170, 130);
x.strokeStyle = '#000000'; x.lineWidth = 3; x.strokeRect(150, 230, 170, 130);
x.fillStyle = '#FF0000'; x.beginPath(); x.moveTo(130, 232); x.lineTo(235, 150); x.lineTo(340, 232); x.closePath(); x.fill(); x.stroke();
x.fillStyle = '#804000'; x.fillRect(215, 290, 40, 70); x.strokeRect(215, 290, 40, 70);
x.fillStyle = '#0080FF'; x.fillRect(170, 255, 34, 30); x.strokeRect(170, 255, 34, 30); x.fillRect(268, 255, 34, 30); x.strokeRect(268, 255, 34, 30);
// cloud
x.fillStyle = '#FFFFFF'; for (const [cx, cy, r] of [[90,70,26],[120,58,32],[155,72,26],[122,80,24]]) { x.beginPath(); x.arc(cx, cy, r, 0, Math.PI*2); x.fill(); }
// a tree: trunk, then an airbrushed crown
x.fillStyle = '#804000'; x.fillRect(486, 300, 12, 70);
let seed = 7; const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
for (let i = 0; i < 2600; i++) { const a = rnd()*Math.PI*2, r = Math.sqrt(rnd())*46; x.fillStyle = i % 3 ? '#00FF00' : '#FFFF80'; x.fillRect(Math.round(492 + Math.cos(a)*r), Math.round(282 + Math.sin(a)*r*0.85), 1, 1); }
await new Promise(r => setTimeout(r, 300));
return [W, H];
