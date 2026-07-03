import { useState, useEffect } from "react";
import {
    Message,
    MessageView,
    ctx,
    ws_client,
    RoomView,
    UserView,
    JsValueMut,
} from "{{project-name}}-wasm-bindings";
import { signalObserver } from "../utils";
import "./MessageInput.css";

interface MessageInputProps {
    room: RoomView;
    currentUser: UserView | null;
    editingMessageMut: JsValueMut<MessageView | null>;
    messages: MessageView[];
    onMessageSent?: () => void;
}

export const MessageInput: React.FC<MessageInputProps> = signalObserver(({ room, currentUser, editingMessageMut, messages, onMessageSent }) => {
    const [messageInput, setMessageInput] = useState("");
    const connectionState = ws_client().connection_state.value?.value();
    const editMsg = editingMessageMut.get();

    // Track the ID of the message being edited to avoid re-render loops
    const editMsgId = editMsg?.id.to_base64();
    const editMsgText = editMsg?.text;

    // Update input when editing message changes
    useEffect(() => {
        if (editMsgId && editMsgText !== undefined) {
            setMessageInput(editMsgText);
        } else {
            setMessageInput("");
        }
    }, [editMsgId, editMsgText]);

    const handleSendMessage = async () => {
        if (!messageInput.trim() || !currentUser) {
            console.log("Cannot send:", { hasInput: !!messageInput.trim(), hasUser: !!currentUser });
            return;
        }

        if (editMsg) {
            // Edit existing message
            const trx = ctx().begin();
            editMsg.edit(trx).text.replace(messageInput.trim());
            await trx.commit();
            console.log("Message updated");
            editingMessageMut.set(null);
            setMessageInput("");
        } else {
            // Create new message - pass View objects (duck typing extracts .id)
            const transaction = ctx().begin();
            const msg = await Message.create(transaction, {
                user: currentUser,
                room: room,
                text: messageInput.trim(),
                timestamp: Date.now(),
                deleted: false,
            });
            console.log("Message created:", msg);
            await transaction.commit();
            setMessageInput("");
            onMessageSent?.();
        }
    };

    const handleKeyDown = (e: React.KeyboardEvent) => {
        if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            handleSendMessage();
        } else if (e.key === "Escape" && editMsg) {
            e.preventDefault();
            editingMessageMut.set(null);
            setMessageInput("");
        } else if (e.key === "ArrowUp" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            if (!currentUser || messages.length === 0) return;

            const userId = currentUser.id;
            // Find next older message by current user
            const currentIdx = editMsg
                ? messages.findIndex(msg => msg.id.equals(editMsg.id))
                : messages.length;

            // Search backward from current position
            for (let i = currentIdx - 1; i >= 0; i--) {
                if (messages[i].user.id.equals(userId)) {
                    editingMessageMut.set(messages[i]);
                    return;
                }
            }
        } else if (e.key === "ArrowDown" && (e.metaKey || e.ctrlKey) && editMsg) {
            e.preventDefault();
            if (!currentUser || messages.length === 0) return;

            const userId = currentUser.id;
            const currentIdx = messages.findIndex(msg => msg.id.equals(editMsg.id));

            // Search forward from current position
            for (let i = currentIdx + 1; i < messages.length; i++) {
                if (messages[i].user.id.equals(userId)) {
                    editingMessageMut.set(messages[i]);
                    return;
                }
            }

            // No more messages, exit edit mode
            editingMessageMut.set(null);
            setMessageInput("");
        }
    };

    return (
        <div className="inputContainer">
            <input
                type="text"
                className="input"
                placeholder="Type a message..."
                value={messageInput}
                onChange={(e) => setMessageInput(e.target.value)}
                onKeyDown={handleKeyDown}
                disabled={connectionState !== "Connected"}
            />
            <button
                className="button"
                onClick={handleSendMessage}
                disabled={!messageInput.trim() || connectionState !== "Connected"}
            >
                {editMsg ? "Update" : "Send"}
            </button>
            {editMsg && (
                <button
                    className="button"
                    onClick={() => {
                        editingMessageMut.set(null);
                        setMessageInput("");
                    }}
                    style={% raw %}{{marginLeft: '8px'}}{% endraw %}
                >
                    Cancel
                </button>
            )}
        </div>
    );
});
