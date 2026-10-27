// A date and time picker for the export dialog, which Lightroom's SDK cannot
// draw: macOS's own calendar and time controls in a standard alert, run with
// osascript (JavaScript for Automation ships with macOS, so nothing to build).
//
//   osascript -l JavaScript DatePicker.js <initial> <earliest> <title>
//
// Times are seconds since 1970. Prints the chosen time in the same form, or
// nothing if cancelled. Nothing before <earliest> can be chosen: both
// controls carry it as their minimum, so the pickers themselves refuse it.

ObjC.import('Cocoa');

// Keeps the calendar and the time field showing one moment. Each holds a full
// date, so whichever is changed is copied to the other; that is also what
// lets one minimum apply to the day and the time together.
ObjC.registerSubclass({
    name: 'SubstackPostPickerSync',
    properties: { calendar: 'id', clock: 'id' },
    methods: {
        'changed:': {
            types: ['void', ['id']],
            implementation: function (sender) {
                const other = sender.isEqual(this.calendar) ? this.clock : this.calendar;
                if (sender.isEqual(this.calendar)) {
                    // A new day, at the time already set, raised to the
                    // minimum if that day is today and the time has passed.
                    const cal = $.NSCalendar.currentCalendar;
                    const time = cal.componentsFromDate(
                        $.NSCalendarUnitHour | $.NSCalendarUnitMinute, this.clock.dateValue);
                    let moment = cal.dateBySettingHourMinuteSecondOfDateOptions(
                        time.hour, time.minute, 0, this.calendar.dateValue, 0);
                    if (moment.compare(this.calendar.minDate) < 0) moment = this.calendar.minDate;
                    this.calendar.dateValue = moment;
                    this.clock.dateValue = moment;
                } else {
                    other.dateValue = sender.dateValue;
                }
            },
        },
    },
});

function picker(style, elements, earliest, initial) {
    const p = $.NSDatePicker.alloc.initWithFrame($.NSZeroRect);
    p.datePickerStyle = style;
    p.datePickerElements = elements;
    p.minDate = earliest;
    p.dateValue = initial;
    p.sizeToFit;
    return p;
}

function run(argv) {
    // Whole minutes: the time field shows no seconds, so a minimum with
    // seconds would let a choice land just under it.
    const minute = n => Math.ceil(Number(n) / 60) * 60;
    const earliest = $.NSDate.dateWithTimeIntervalSince1970(minute(argv[1]));
    const initial = $.NSDate.dateWithTimeIntervalSince1970(
        Math.max(minute(argv[0]), minute(argv[1])));

    // Lightroom is the frontmost app until this one activates, and its icon
    // says where the question comes from better than osascript's would.
    const caller = $.NSWorkspace.sharedWorkspace.frontmostApplication;
    const app = $.NSApplication.sharedApplication;

    const calendar = picker($.NSDatePickerStyleClockAndCalendar,
        $.NSDatePickerElementFlagYearMonthDay, earliest, initial);
    // Typed, not stepped: digits for the time, "a" or "p" for AM/PM.
    const clock = picker($.NSDatePickerStyleTextField,
        $.NSDatePickerElementFlagHourMinute, earliest, initial);
    clock.bezeled = true;
    clock.drawsBackground = true;

    const sync = $.SubstackPostPickerSync.alloc.init;
    sync.calendar = calendar;
    sync.clock = clock;
    for (const p of [calendar, clock]) {
        p.target = sync;
        p.action = 'changed:';
    }

    const gap = 8;
    const c = calendar.frame.size;
    const t = clock.frame.size;
    const box = $.NSView.alloc.initWithFrame(
        $.NSMakeRect(0, 0, Math.max(c.width, t.width), c.height + gap + t.height));
    calendar.setFrameOrigin($.NSMakePoint(0, t.height + gap));
    clock.setFrameOrigin($.NSMakePoint(0, 0));
    box.addSubview(calendar);
    box.addSubview(clock);

    const alert = $.NSAlert.alloc.init;
    alert.messageText = argv[2] || 'Schedule';
    alert.addButtonWithTitle('OK');
    alert.addButtonWithTitle('Cancel');
    alert.accessoryView = box;
    if (!caller.isNil()) alert.icon = caller.icon;

    // Lightroom's export dialog is itself a modal panel, and stays in front
    // of another app's window at the same level. This one must sit above it.
    alert.layout;
    alert.window.level = $.NSStatusWindowLevel;
    alert.window.initialFirstResponder = clock;
    // osascript is not allowed to become the active app by default, and a
    // window in an app that is never active never gets the keyboard: the
    // time field takes clicks but not typing. An accessory app can be active
    // without a Dock icon or menu bar.
    app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
    app.activateIgnoringOtherApps(true);

    // runModal puts the window back at the modal panel level, so raise it
    // again once it is showing, in case activation was refused.
    $.NSRunLoop.currentRunLoop.addTimerForMode(
        $.NSTimer.timerWithTimeIntervalRepeatsBlock(0, false, () => {
            alert.window.level = $.NSStatusWindowLevel;
        }),
        $.NSModalPanelRunLoopMode);

    const answer = alert.runModal;
    if (String(answer) !== String($.NSAlertFirstButtonReturn)) return '';
    return String(Math.round(clock.dateValue.timeIntervalSince1970));
}
