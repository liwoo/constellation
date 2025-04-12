// assets/js/user_socket.js
import {Socket, Presence} from "phoenix"

// Make Phoenix and Presence available globally
window.Phoenix = Socket
window.Presence = Presence

// Create a socket instance
let socket = new Socket("/socket", {})

// Export the socket for use in other modules
export default socket
