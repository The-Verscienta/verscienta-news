import { Socket } from 'phoenix';
let socket: Socket | null = null;

export function getSocket(token?: string) {
  if (socket) return socket;
  socket = new Socket('/socket', { params: token ? { token } : {} });
  socket.connect();
  return socket;
}

export function joinRoom(topic: string, onMessage: (payload: unknown) => void) {
  const s = getSocket();
  const chan = s.channel(topic, {});
  chan.on('new_msg', onMessage);
  chan.join().receive('ok', () => console.log(`joined ${topic}`));
  return chan;
}
