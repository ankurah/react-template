import { useMemo, useEffect, useRef, useCallback, useState } from "react";
import {
    User, ctx, JsValueRead, JsValueMut, RoomView, UserView, MessageView, MessageScrollManager,
} from "ankurah-template-wasm-bindings";
import { MessageRow } from "./MessageRow";
import { MessageInput } from "./MessageInput";
import { ChatDebugHeader } from "./ChatDebugHeader";
import { signalObserver } from "../utils";
import { NotificationManager } from "../NotificationManager";
import { useDebugMode } from "../hooks/useDebugMode";
import "./Chat.css";

// ankurah-virtual-scroll tuning. viewport_height is a constructor argument in the
// current API (there is no runtime setter), so we measure the container and feed it in.
const MIN_ROW_HEIGHT = 40;
const BUFFER_FACTOR = 2.0;
const DEFAULT_VIEWPORT_HEIGHT = 600;

interface ChatProps {
    room: JsValueRead<RoomView | null>;
    currentUser: JsValueRead<UserView | null>;
    notificationManager: NotificationManager | null;
}

export const Chat: React.FC<ChatProps> = signalObserver(({ room, currentUser, notificationManager }) => {
    const currentRoom = room.get();
    const user = currentUser.get();
    const roomId = currentRoom?.id.to_base64() ?? null;
    const { showDebug, toggleDebug } = useDebugMode();

    const editingMessageMut = useMemo(() => new JsValueMut<MessageView | null>(null), []);
    const editingMessage = editingMessageMut.get();

    const containerRef = useRef<HTMLDivElement | null>(null);
    const lastScrollTopRef = useRef(0);
    const [viewportHeight, setViewportHeight] = useState(DEFAULT_VIEWPORT_HEIGHT);

    // Recreate the manager when the room or the measured viewport height changes
    // (viewport height is a constructor argument in ankurah-virtual-scroll 0.8).
    const manager = useMemo(() => {
        if (!roomId) return null;
        const m = new MessageScrollManager(
            ctx(),
            `room = '${roomId}' AND deleted = false`,
            'timestamp DESC',
            MIN_ROW_HEIGHT,
            BUFFER_FACTOR,
            viewportHeight,
        );
        m.start();
        return m;
    }, [roomId, viewportHeight]);

    const visibleSet = useMemo(() => manager?.visibleSet() ?? null, [manager])?.get() ?? null;
    const users = useMemo(() => User.query(ctx(), ""), []);
    const shouldAutoScroll = visibleSet?.shouldAutoScroll() ?? false;

    const scrollToBottom = useCallback(() => {
        if (containerRef.current) containerRef.current.scrollTop = containerRef.current.scrollHeight;
    }, []);

    // Ref callback: capture the container and its height. Updating viewportHeight
    // recreates the manager; the >1px guard keeps that from looping.
    const bindContainer = useCallback((el: HTMLDivElement | null) => {
        containerRef.current = el;
        if (el) {
            lastScrollTopRef.current = el.scrollTop;
            const h = el.clientHeight;
            if (h > 0) setViewportHeight((prev) => (Math.abs(prev - h) > 1 ? h : prev));
        }
    }, []);

    // The current API is intersection/EntityId-based: report the first and last
    // *visible* message elements by their EntityId, not pixel offsets.
    const findVisibleIds = useCallback((): { firstId: string; lastId: string } | null => {
        const container = containerRef.current;
        if (!container) return null;
        const containerRect = container.getBoundingClientRect();
        let firstId: string | null = null;
        let lastId: string | null = null;
        container.querySelectorAll<HTMLElement>('[data-msg-id]').forEach((el) => {
            const rect = el.getBoundingClientRect();
            if (rect.bottom > containerRect.top && rect.top < containerRect.bottom) {
                const id = el.getAttribute('data-msg-id');
                if (id) {
                    if (!firstId) firstId = id;
                    lastId = id;
                }
            }
        });
        return firstId && lastId ? { firstId, lastId } : null;
    }, []);

    const handleScroll = useCallback(() => {
        if (!manager || !containerRef.current) return;
        const scrollTop = containerRef.current.scrollTop;
        const scrollingBackward = scrollTop < lastScrollTopRef.current;
        lastScrollTopRef.current = scrollTop;
        const visible = findVisibleIds();
        if (visible) manager.onScroll(visible.firstId, visible.lastId, scrollingBackward);
        notificationManager?.setActiveRoom(manager.mode === 'Live' ? roomId : null);
    }, [manager, notificationManager, roomId, findVisibleIds]);

    // No jumpToLive() in the current API: scrolling to the bottom drops the manager
    // back into Live/auto-scroll on the next onScroll.
    const handleJumpToLive = useCallback(() => {
        scrollToBottom();
        notificationManager?.setActiveRoom(roomId);
    }, [scrollToBottom, notificationManager, roomId]);

    const handleMessageSent = useCallback(() => {
        if (manager?.mode === 'Live') setTimeout(scrollToBottom, 100);
    }, [manager, scrollToBottom]);

    useEffect(() => {
        if (shouldAutoScroll && manager?.mode === 'Live') scrollToBottom();
    }, [shouldAutoScroll, manager, scrollToBottom]);

    useEffect(() => {
        if (manager?.mode === 'Live' && notificationManager && roomId) notificationManager.setActiveRoom(roomId);
    }, [manager, notificationManager, roomId]);

    const messages = visibleSet?.items ?? [];
    const showJumpToCurrent = manager && visibleSet && !shouldAutoScroll && manager.mode !== 'Live';

    if (!currentRoom) {
        return <div className="chatContainer"><div className="emptyState">Select a room to start chatting</div></div>;
    }

    return (
        <div className="chatContainer">
            {manager && showDebug && (
                <ChatDebugHeader
                    mode={manager.mode}
                    hasMorePreceding={visibleSet?.hasMorePreceding() ?? false}
                    hasMoreFollowing={visibleSet?.hasMoreFollowing() ?? false}
                    shouldAutoScroll={shouldAutoScroll}
                    itemCount={messages.length}
                />
            )}
            {manager && (
                <button className="debugToggle" onClick={toggleDebug} title={showDebug ? "Hide debug info" : "Show debug info"} style={{ opacity: 0.35 }}>
                    {showDebug ? "v" : "^"}
                </button>
            )}
            <div className="messagesContainer" ref={bindContainer} onScroll={handleScroll}>
                {messages.length === 0
                    ? <div className="emptyState">No messages yet. Be the first to say hello!</div>
                    : messages.map((msg) => (
                        <MessageRow key={msg.id.toString()} message={msg} users={users} currentUserId={user?.id || null} editingMessage={editingMessage} editingMessageMut={editingMessageMut} />
                    ))}
            </div>
            {showJumpToCurrent && <button className="jumpToCurrent" onClick={handleJumpToLive}>Jump to Current v</button>}
            <MessageInput room={currentRoom} currentUser={user} editingMessageMut={editingMessageMut} messages={messages} onMessageSent={handleMessageSent} />
        </div>
    );
});
