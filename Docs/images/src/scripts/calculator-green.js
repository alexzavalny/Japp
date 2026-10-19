const k = s => document.querySelector(s).click();
k('[data-digit="1"]'); k('[data-digit="2"]'); k('[data-digit="8"]'); k('[data-operator="×"]'); k('[data-digit="1"]'); k('[data-digit="2"]');
document.documentElement.style.setProperty("--key-operator", "#30d158");
await new Promise(r => setTimeout(r, 300));
return document.getElementById('result').textContent;
