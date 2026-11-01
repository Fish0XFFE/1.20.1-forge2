package com.fish.korolevcross.gpu;

import java.lang.reflect.Field;

final class Fields {
    private Fields() {
    }

    static Field get(Class<?> owner, String name) {
        try {
            Field field = owner.getDeclaredField(name);
            field.setAccessible(true);
            return field;
        } catch (NoSuchFieldException ignored) {
        }
        String srg = SrgNames.srg(owner.getName(), name);
        if (srg != null) {
            try {
                Field field = owner.getDeclaredField(srg);
                field.setAccessible(true);
                return field;
            } catch (NoSuchFieldException ignored) {
            }
        }
        throw new IllegalStateException("field " + name + " not found on " + owner.getName());
    }
}
