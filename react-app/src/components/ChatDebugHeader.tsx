import "./ChatDebugHeader.css";

interface ChatDebugHeaderProps {
    mode: string;
    hasMorePreceding: boolean;
    hasMoreFollowing: boolean;
    shouldAutoScroll: boolean;
    itemCount: number;
}

export const ChatDebugHeader: React.FC<ChatDebugHeaderProps> = ({
    mode,
    hasMorePreceding,
    hasMoreFollowing,
    shouldAutoScroll,
    itemCount,
}) => {
    return (
        <div className="debugHeader">
            <div className="debugRow">
                <span className="debugLabel">Mode:</span>
                <span className={`debugValue mode-${mode.toLowerCase()}`}>{mode}</span>
                <span className="debugLabel">Items:</span>
                <span className="debugValue">{itemCount}</span>
            </div>
            <div className="debugRow">
                <span className="debugLabel">More preceding:</span>
                <span className="debugValue">{hasMorePreceding ? 'yes' : 'no'}</span>
                <span className="debugLabel">More following:</span>
                <span className="debugValue">{hasMoreFollowing ? 'yes' : 'no'}</span>
                <span className="debugLabel">Auto-scroll:</span>
                <span className="debugValue">{shouldAutoScroll ? 'yes' : 'no'}</span>
            </div>
        </div>
    );
};
