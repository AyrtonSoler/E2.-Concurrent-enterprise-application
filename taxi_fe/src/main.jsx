import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'

// Nota: no usamos StrictMode porque su doble-montaje en desarrollo provoca un
// join/leave/join inmediato sobre el mismo topic del socket, y el cliente
// phoenix-socket (protocolo V1) pierde los mensajes tras ese rejoin.
createRoot(document.getElementById('root')).render(
  <App />,
)
