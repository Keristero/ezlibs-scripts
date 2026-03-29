local announcments = {
    {
        id = "ANN_EXAMPLE_001",
        icon = 1,
        title = "Server Maintenance",
        from = "Admin",
        body = "The server will restart in 10 minutes for maintenance.\nPlease log out to avoid issues.",
        mug_texture_path = "",
        mug_animation_path = "",
        starts_at = 0,        -- optional: timestamp when it becomes active
        ends_at = nil,        -- optional: expiry timestamp
        priority = 0,         -- higher = more likely to trigger the ring
        notify_message = "New server announcement: Server Maintenance",
    }
}
return announcments