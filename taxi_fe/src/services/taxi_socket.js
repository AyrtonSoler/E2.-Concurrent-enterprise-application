import { Socket } from 'phoenix-socket';

let socket = new Socket('ws://localhost:4000/socket', {params: {userToken: '123'}});
socket.connect();

export default socket;