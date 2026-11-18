// Demonstrates the receiving side only; never builds, deploys or backs up anything.
const services = JSON.parse(process.argv[2]);
if (!Array.isArray(services) || !services.length || services.some(s => !['frontend', 'backend', 'runtime'].includes(s))) throw Error('Invalid services');
if (!['true', 'false'].includes(process.env.BACKUP_DATABASE)) throw Error('Invalid backup flag');
console.log('Demo only — no deployment or database access.');
console.log(JSON.stringify({ services, backup: process.env.BACKUP_DATABASE === 'true' }));
