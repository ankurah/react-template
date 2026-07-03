import React, { useState, useEffect } from "react";
import { createAnkurahReactHooks } from "@ankurah/react-hooks";
import { ReactObserver, User, ctx, EntityId, UserView, JsValueMut, JsValueRead } from "{{project-name}}-wasm-bindings";

// Create hooks bound to WASM bindings
const { useObserve, signalObserver } = createAnkurahReactHooks({ React, ReactObserver });
export { useObserve, signalObserver };

export function useAsync<T>(fn: () => Promise<T>, deps: React.DependencyList): T | null {
    const [value, setValue] = useState<T | null>(null);
    useEffect(() => {
        fn().then(setValue);
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, deps);
    return value;
}

// LocalStorage keys
const STORAGE_KEY_USER_ID = "{{crate_name}}_user_id";

export function ensureUser(): JsValueRead<UserView | null> {
    const [userMut, userRead] = JsValueMut.newPair<UserView | null>(null);

    const createNewUser = async (context: ReturnType<typeof ctx>) => {
        const transaction = context.begin();
        const userView = await User.create(transaction, {
            display_name: `User-${Math.floor(Math.random() * 10000)}`,
        });
        await transaction.commit();
        localStorage.setItem(STORAGE_KEY_USER_ID, userView.id.to_base64());
        return userView;
    };

    // WORKAROUND: ankurah get_entity creates empty entities for non-existent IDs
    // instead of returning EntityNotFound. See https://github.com/ankurah/ankurah/issues/196
    const isValidUser = (user: UserView): boolean => {
        try {
            user.display_name; // Throws "property is missing" if entity is empty
            return true;
        } catch {
            return false;
        }
    };

    const initUser = async () => {
        try {
            const context = ctx();
            const storedUserId = localStorage.getItem(STORAGE_KEY_USER_ID);

            if (storedUserId) {
                try {
                    const user = await User.get(context, EntityId.from_base64(storedUserId));
                    if (isValidUser(user)) {
                        userMut.set(user);
                        return;
                    }
                    // User exists but is empty/invalid - clear and recreate
                    console.warn("Stored user is invalid, creating new user");
                } catch {
                    console.warn("Failed to fetch stored user, creating new user");
                }
                localStorage.removeItem(STORAGE_KEY_USER_ID);
            }

            const userView = await createNewUser(context);
            userMut.set(userView);
        } catch (error) {
            console.error("Failed to initialize user:", error);
        }
    };

    initUser();
    return userRead;
}
