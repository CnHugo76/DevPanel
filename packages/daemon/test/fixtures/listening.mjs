import { createServer } from "node:net";
const server = createServer();
server.listen(Number(process.argv[3] || 0), process.argv[2], () =>
  console.log(JSON.stringify(server.address())),
);
