#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#include <util.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>

extern char **environ;

#pragma mark - Terminal View Controller

@interface TerminalViewController : UIViewController <UITextFieldDelegate>

@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIScrollView *toolbarScroll;
@property (nonatomic, strong) UIView *bottomContainer;
@property (nonatomic, assign) int masterFD;
@property (nonatomic, assign) pid_t shellPID;
@property (nonatomic, strong) NSMutableAttributedString *outputBuffer;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, assign) CGFloat keyboardHeight;
@property (nonatomic, strong) NSLayoutConstraint *bottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *bottomHeightConstraint;
@property (nonatomic, assign) BOOL pendingUpdate;
@property (nonatomic, strong) NSMutableArray *commandHistory;
@property (nonatomic, assign) NSInteger historyIndex;
@property (nonatomic, assign) BOOL isPasswordMode;

// ANSI state
@property (nonatomic, strong) UIColor *currentFGColor;
@property (nonatomic, strong) UIColor *currentBGColor;
@property (nonatomic, assign) BOOL isBold;
@property (nonatomic, strong) UIFont *normalFont;
@property (nonatomic, strong) UIFont *boldFont;

// Line buffer for cursor positioning
@property (nonatomic, strong) NSMutableArray *lineBuffer;  // Array of attributed strings for each column
@property (nonatomic, assign) NSInteger cursorCol;
@property (nonatomic, assign) NSInteger lineWidth;

@end

@implementation TerminalViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.outputBuffer = [[NSMutableAttributedString alloc] init];
    self.commandHistory = [NSMutableArray array];
    self.historyIndex = -1;
    self.masterFD = -1;
    self.shellPID = 0;
    self.keyboardHeight = 0;
    self.pendingUpdate = NO;
    
    // Initialize ANSI state
    self.currentFGColor = [UIColor blackColor]; // Default black for white background
    self.currentBGColor = nil;
    self.isBold = NO;
    
    // Setup fonts
    self.normalFont = [UIFont fontWithName:@"MesloLGS-NF-Regular" size:14] ?: [UIFont fontWithName:@"MesloLGS NF" size:14] ?: [UIFont fontWithName:@"Menlo" size:14] ?: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.boldFont = [UIFont fontWithName:@"MesloLGS-NF-Bold" size:14] ?: [UIFont fontWithName:@"MesloLGS NF Bold" size:14] ?: [UIFont fontWithName:@"Menlo-Bold" size:14] ?: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightBold];
    
    // Line buffer for cursor positioning - will be resized after layout
    self.lineWidth = 80;  // Default, will be updated
    self.cursorCol = 0;
    self.lineBuffer = [NSMutableArray arrayWithCapacity:200];
    for (int i = 0; i < 200; i++) {
        [self.lineBuffer addObject:[NSNull null]];
    }
    
    [self setupUI];
    [self setupKeyboardObservers];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updateTerminalSize];
    [self startShell];
    // Delay keyboard activation to let layout complete
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.inputField becomeFirstResponder];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updateTerminalSize];
}

- (void)updateTerminalSize {
    if (!self.textView || !self.normalFont) return;
    
    // Calculate character width using the font
    CGSize charSize = [@"M" sizeWithAttributes:@{NSFontAttributeName: self.normalFont}];
    CGFloat charWidth = charSize.width;
    CGFloat charHeight = charSize.height;
    
    if (charWidth > 0 && charHeight > 0) {
        CGFloat textViewWidth = self.textView.bounds.size.width - 16; // Account for padding
        CGFloat textViewHeight = self.textView.bounds.size.height;
        
        NSInteger newCols = (NSInteger)(textViewWidth / charWidth);
        NSInteger newRows = (NSInteger)(textViewHeight / charHeight);
        
        if (newCols < 40) newCols = 40;
        if (newCols > 200) newCols = 200;
        if (newRows < 10) newRows = 10;
        if (newRows > 100) newRows = 100;
        
        self.lineWidth = newCols;
        
        // Update PTY window size if shell is running
        if (self.masterFD >= 0) {
            struct winsize ws = {.ws_row = (unsigned short)newRows, .ws_col = (unsigned short)newCols};
            ioctl(self.masterFD, TIOCSWINSZ, &ws);
        }
    }
}

- (void)setupUI {
    self.view.backgroundColor = [UIColor whiteColor];
    
    // Bottom container (toolbar + input)
    self.bottomContainer = [[UIView alloc] init];
    self.bottomContainer.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.97 alpha:1.0];
    self.bottomContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.bottomContainer];
    
    // Text view for output
    self.textView = [[UITextView alloc] init];
    self.textView.backgroundColor = [UIColor whiteColor];
    self.textView.textColor = [UIColor blackColor];
    self.textView.editable = NO;
    self.textView.attributedText = self.outputBuffer;
    self.textView.translatesAutoresizingMaskIntoConstraints = NO;
    self.textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:self.textView];
    
    // Toolbar row 1 - commands
    self.toolbarScroll = [[UIScrollView alloc] init];
    self.toolbarScroll.showsHorizontalScrollIndicator = NO;
    self.toolbarScroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.toolbarScroll.backgroundColor = [UIColor colorWithRed:0.92 green:0.92 blue:0.94 alpha:1.0];
    [self.bottomContainer addSubview:self.toolbarScroll];
    
    NSArray *buttons = @[
        @[@"↑", @"HISTORY_UP"],
        @[@"↓", @"HISTORY_DOWN"],
        @[@"Ctrl+C", @"\x03"],
        @[@"Ctrl+D", @"\x04"],
        @[@"Ctrl+U", @"CLEAR_INPUT"],
        @[@"Clear", @"CLEAR_SCREEN"],
        @[@"📷", @"SCREENSHOT"],
        @[@"mf2", @"SSH_MF2"],
    ];
    
    CGFloat x = 8;
    for (NSArray *btn in buttons) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(x, 4, 65, 32);
        [b setTitle:btn[0] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor darkGrayColor] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithRed:0.85 green:0.85 blue:0.87 alpha:1.0];
        b.layer.cornerRadius = 4;
        b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        b.accessibilityIdentifier = btn[1];
        [b addTarget:self action:@selector(toolbarTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.toolbarScroll addSubview:b];
        x += 73;
    }
    self.toolbarScroll.contentSize = CGSizeMake(x, 40);
    
    // Toolbar row 2 - special characters
    UIScrollView *symbolScroll = [[UIScrollView alloc] init];
    symbolScroll.showsHorizontalScrollIndicator = NO;
    symbolScroll.translatesAutoresizingMaskIntoConstraints = NO;
    symbolScroll.backgroundColor = [UIColor colorWithRed:0.92 green:0.92 blue:0.94 alpha:1.0];
    symbolScroll.tag = 100;
    [self.bottomContainer addSubview:symbolScroll];
    
    NSArray *symbols = @[@"-", @"=", @"/", @"_", @"*", @".", @":", @"@", @"#", @"|", @"\\", @"&", @"~", @"$", @"\"", @"'", @";", @"<", @">", @"?"];
    
    CGFloat sx = 8;
    for (NSString *sym in symbols) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(sx, 4, 36, 32);
        [b setTitle:sym forState:UIControlStateNormal];
        [b setTitleColor:[UIColor darkGrayColor] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithRed:0.85 green:0.85 blue:0.87 alpha:1.0];
        b.layer.cornerRadius = 4;
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        b.accessibilityIdentifier = [NSString stringWithFormat:@"INSERT:%@", sym];
        [b addTarget:self action:@selector(toolbarTapped:) forControlEvents:UIControlEventTouchUpInside];
        [symbolScroll addSubview:b];
        sx += 44;
    }
    symbolScroll.contentSize = CGSizeMake(sx, 40);
    
    // Input field
    self.inputField = [[UITextField alloc] init];
    self.inputField.backgroundColor = [UIColor colorWithRed:0.98 green:0.98 blue:0.98 alpha:1.0];
    self.inputField.textColor = [UIColor blackColor];
    self.inputField.tintColor = [UIColor blueColor];
    self.inputField.font = [UIFont fontWithName:@"MesloLGS NF" size:16] ?: [UIFont fontWithName:@"MesloLGS-NF-Regular" size:16] ?: [UIFont fontWithName:@"Menlo" size:16] ?: [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
    self.inputField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"输入命令..." attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.5 alpha:1.0]}];
    self.inputField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inputField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.inputField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.inputField.returnKeyType = UIReturnKeySend;
    self.inputField.delegate = self;
    self.inputField.layer.cornerRadius = 8;
    self.inputField.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1.0].CGColor;
    self.inputField.layer.borderWidth = 1;
    self.inputField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
    self.inputField.leftViewMode = UITextFieldViewModeAlways;
    self.inputField.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
    self.inputField.rightViewMode = UITextFieldViewModeAlways;
    self.inputField.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bottomContainer addSubview:self.inputField];
    
    // Layout constraints
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    
    self.bottomConstraint = [self.bottomContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    
    [NSLayoutConstraint activateConstraints:@[
        // Bottom container
        [self.bottomContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.bottomContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.bottomConstraint,
        
        // Text view
        [self.textView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [self.textView.bottomAnchor constraintEqualToAnchor:self.bottomContainer.topAnchor constant:-8],
        
        // Toolbar row 1
        [self.toolbarScroll.topAnchor constraintEqualToAnchor:self.bottomContainer.topAnchor constant:4],
        [self.toolbarScroll.leadingAnchor constraintEqualToAnchor:self.bottomContainer.leadingAnchor],
        [self.toolbarScroll.trailingAnchor constraintEqualToAnchor:self.bottomContainer.trailingAnchor],
        [self.toolbarScroll.heightAnchor constraintEqualToConstant:40],
        
        // Toolbar row 2 (symbols)
        [symbolScroll.topAnchor constraintEqualToAnchor:self.toolbarScroll.bottomAnchor constant:2],
        [symbolScroll.leadingAnchor constraintEqualToAnchor:self.bottomContainer.leadingAnchor],
        [symbolScroll.trailingAnchor constraintEqualToAnchor:self.bottomContainer.trailingAnchor],
        [symbolScroll.heightAnchor constraintEqualToConstant:40],
        
        // Input field
        [self.inputField.topAnchor constraintEqualToAnchor:symbolScroll.bottomAnchor constant:4],
        [self.inputField.leadingAnchor constraintEqualToAnchor:self.bottomContainer.leadingAnchor constant:8],
        [self.inputField.trailingAnchor constraintEqualToAnchor:self.bottomContainer.trailingAnchor constant:-8],
        [self.inputField.heightAnchor constraintEqualToConstant:44],
    ]];
    
    // Set up height constraint based on orientation
    self.bottomHeightConstraint = [self.bottomContainer.heightAnchor constraintEqualToConstant:140];
    self.bottomHeightConstraint.active = YES;
    [self updateLayoutForOrientation];
}

- (void)updateLayoutForOrientation {
    BOOL isLandscape = self.view.bounds.size.width > self.view.bounds.size.height;
    self.bottomHeightConstraint.constant = isLandscape ? 100 : 140;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        BOOL isLandscape = size.width > size.height;
        self.bottomHeightConstraint.constant = isLandscape ? 100 : 140;
        [self.view layoutIfNeeded];
        [self updateTerminalSize];
    } completion:nil];
}

- (void)setupKeyboardObservers {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    CGRect keyboardFrame = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [info[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    
    // Convert keyboard frame to view coordinates for proper landscape handling
    CGRect convertedFrame = [self.view convertRect:keyboardFrame fromView:nil];
    CGFloat keyboardHeight = self.view.bounds.size.height - convertedFrame.origin.y;
    
    if (keyboardHeight < 0) keyboardHeight = 0;
    
    self.bottomConstraint.constant = -keyboardHeight;
    
    [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
        [self.view layoutIfNeeded];
    } completion:^(BOOL finished) {
        [self scrollToBottom];
    }];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [info[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    
    self.bottomConstraint.constant = 0;
    
    [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)scrollToBottom {
    if (self.outputBuffer.length > 0) {
        NSRange range = NSMakeRange(self.outputBuffer.length - 1, 1);
        [self.textView scrollRangeToVisible:range];
    }
}

- (void)toolbarTapped:(UIButton *)sender {
    NSString *cmd = sender.accessibilityIdentifier;
    if (!cmd) return;
    
    if ([cmd hasPrefix:@"INSERT:"]) {
        // Insert character into input field
        NSString *ch = [cmd substringFromIndex:7];
        [self insertTextAtCursor:ch];
    } else if ([cmd isEqualToString:@"CLEAR_SCREEN"]) {
        // Clear local buffer and reset line buffer
        self.outputBuffer = [[NSMutableAttributedString alloc] init];
        self.cursorCol = 0;
        for (NSInteger j = 0; j < self.lineWidth; j++) {
            self.lineBuffer[j] = [NSNull null];
        }
        self.textView.attributedText = self.outputBuffer;
        [self.textView setContentOffset:CGPointZero animated:NO];
        // Send Ctrl+L to redraw prompt without showing "clear" text
        if (self.masterFD >= 0) {
            write(self.masterFD, "\x0c", 1);
        }
    } else if ([cmd isEqualToString:@"SCREENSHOT"]) {
        // Take screenshot using activator
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            pid_t pid;
            char *argv[] = {"/usr/bin/activator", "send", "libactivator.system.take-screenshot", NULL};
            posix_spawn(&pid, "/usr/bin/activator", NULL, NULL, argv, environ);
        });
    } else if ([cmd isEqualToString:@"SSH_MF2"]) {
        // Clear entire display before SSH to avoid duplicate prompts
        self.outputBuffer = [[NSMutableAttributedString alloc] init];
        self.cursorCol = 0;
        for (NSInteger j = 0; j < self.lineWidth; j++) {
            self.lineBuffer[j] = [NSNull null];
        }
        self.textView.attributedText = self.outputBuffer;
        // Execute ssh mf2
        if (self.masterFD >= 0) {
            write(self.masterFD, "ssh mf2\n", 8);
        }
    } else if ([cmd isEqualToString:@"ENTER"]) {
        [self sendCurrentCommand];
    } else if ([cmd isEqualToString:@"HISTORY_UP"]) {
        [self historyUp];
    } else if ([cmd isEqualToString:@"HISTORY_DOWN"]) {
        [self historyDown];
    } else if ([cmd isEqualToString:@"CURSOR_LEFT"]) {
        [self moveCursorLeft];
    } else if ([cmd isEqualToString:@"CURSOR_RIGHT"]) {
        [self moveCursorRight];
    } else if ([cmd isEqualToString:@"BACKSPACE"]) {
        [self deleteBackward];
    } else if ([cmd isEqualToString:@"CLEAR_INPUT"]) {
        self.inputField.text = @"";
    } else if (self.masterFD >= 0) {
        // Send directly to shell (Tab, Ctrl+C, Ctrl+D)
        write(self.masterFD, [cmd UTF8String], [cmd lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    }
}

- (void)sendCurrentCommand {
    NSString *text = self.inputField.text;
    if (text.length > 0 && self.masterFD >= 0) {
        // Don't save passwords to history
        if (!self.isPasswordMode) {
            [self.commandHistory addObject:text];
            self.historyIndex = self.commandHistory.count;
        }
        
        // Send command
        NSString *cmd = [text stringByAppendingString:@"\n"];
        write(self.masterFD, [cmd UTF8String], [cmd lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
        self.inputField.text = @"";
        
        // Reset password mode
        if (self.isPasswordMode) {
            self.isPasswordMode = NO;
            self.inputField.secureTextEntry = NO;
            self.inputField.placeholder = @"Enter command...";
        }
    } else if (self.masterFD >= 0) {
        write(self.masterFD, "\n", 1);
    }
}

- (void)historyUp {
    if (self.commandHistory.count == 0) return;
    
    if (self.historyIndex > 0) {
        self.historyIndex--;
    } else if (self.historyIndex == -1) {
        self.historyIndex = self.commandHistory.count - 1;
    }
    
    if (self.historyIndex >= 0 && self.historyIndex < (NSInteger)self.commandHistory.count) {
        self.inputField.text = self.commandHistory[self.historyIndex];
    }
}

- (void)historyDown {
    if (self.commandHistory.count == 0) return;
    
    if (self.historyIndex < (NSInteger)self.commandHistory.count - 1) {
        self.historyIndex++;
        self.inputField.text = self.commandHistory[self.historyIndex];
    } else {
        self.historyIndex = self.commandHistory.count;
        self.inputField.text = @"";
    }
}

- (void)moveCursorLeft {
    UITextRange *range = self.inputField.selectedTextRange;
    if (range) {
        UITextPosition *newPos = [self.inputField positionFromPosition:range.start offset:-1];
        if (newPos) {
            self.inputField.selectedTextRange = [self.inputField textRangeFromPosition:newPos toPosition:newPos];
        }
    }
}

- (void)moveCursorRight {
    UITextRange *range = self.inputField.selectedTextRange;
    if (range) {
        UITextPosition *newPos = [self.inputField positionFromPosition:range.end offset:1];
        if (newPos) {
            self.inputField.selectedTextRange = [self.inputField textRangeFromPosition:newPos toPosition:newPos];
        }
    }
}

- (void)deleteBackward {
    UITextRange *range = self.inputField.selectedTextRange;
    if (range && !range.isEmpty) {
        [self.inputField replaceRange:range withText:@""];
    } else if (range) {
        UITextPosition *newStart = [self.inputField positionFromPosition:range.start offset:-1];
        if (newStart) {
            UITextRange *deleteRange = [self.inputField textRangeFromPosition:newStart toPosition:range.start];
            [self.inputField replaceRange:deleteRange withText:@""];
        }
    }
}

- (void)insertTextAtCursor:(NSString *)text {
    UITextRange *range = self.inputField.selectedTextRange;
    if (range) {
        [self.inputField replaceRange:range withText:text];
    } else {
        self.inputField.text = [self.inputField.text stringByAppendingString:text];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self sendCurrentCommand];
    return NO;
}

- (UIColor *)ansiColorForCode:(int)code bright:(BOOL)bright {
    // Standard ANSI colors - darker/softer for white background
    UIColor *colors[8] = {
        [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:1.0],      // 0 Black
        [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:1.0],    // 1 Red
        [UIColor colorWithRed:0.15 green:0.5 blue:0.15 alpha:1.0],    // 2 Green (darker)
        [UIColor colorWithRed:0.6 green:0.5 blue:0.0 alpha:1.0],      // 3 Yellow/Brown
        [UIColor colorWithRed:0.15 green:0.3 blue:0.7 alpha:1.0],     // 4 Blue
        [UIColor colorWithRed:0.6 green:0.15 blue:0.6 alpha:1.0],     // 5 Magenta
        [UIColor colorWithRed:0.15 green:0.5 blue:0.5 alpha:1.0],     // 6 Cyan (darker)
        [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0],      // 7 White -> Gray
    };
    
    UIColor *brightColors[8] = {
        [UIColor colorWithRed:0.35 green:0.35 blue:0.35 alpha:1.0],   // 0 Bright Black (Gray)
        [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1.0],   // 1 Bright Red
        [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1.0],      // 2 Bright Green (softer)
        [UIColor colorWithRed:0.7 green:0.6 blue:0.1 alpha:1.0],      // 3 Bright Yellow
        [UIColor colorWithRed:0.3 green:0.5 blue:0.85 alpha:1.0],     // 4 Bright Blue
        [UIColor colorWithRed:0.75 green:0.3 blue:0.75 alpha:1.0],    // 5 Bright Magenta
        [UIColor colorWithRed:0.2 green:0.6 blue:0.6 alpha:1.0],      // 6 Bright Cyan (softer)
        [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0],      // 7 Bright White -> Dark Gray
    };
    
    if (code >= 0 && code < 8) {
        return bright ? brightColors[code] : colors[code];
    }
    return nil;
}

- (UIColor *)color256ForCode:(int)code {
    if (code < 8) {
        return [self ansiColorForCode:code bright:NO];
    } else if (code < 16) {
        return [self ansiColorForCode:code - 8 bright:YES];
    } else if (code < 232) {
        // 216 color cube: 6x6x6
        int idx = code - 16;
        int r = (idx / 36) * 51;
        int g = ((idx / 6) % 6) * 51;
        int b = (idx % 6) * 51;
        return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
    } else {
        // Grayscale: 24 shades
        int gray = (code - 232) * 10 + 8;
        return [UIColor colorWithRed:gray/255.0 green:gray/255.0 blue:gray/255.0 alpha:1.0];
    }
}

- (void)parseAnsiCode:(NSString *)code {
    // Parse SGR (Select Graphic Rendition) codes
    NSArray *parts = [code componentsSeparatedByString:@";"];
    
    for (NSUInteger i = 0; i < parts.count; i++) {
        int n = [parts[i] intValue];
        
        if (n == 0) {
            // Reset
            self.currentFGColor = [UIColor blackColor];
            self.currentBGColor = nil;
            self.isBold = NO;
        } else if (n == 1) {
            self.isBold = YES;
        } else if (n == 22) {
            self.isBold = NO;
        } else if (n >= 30 && n <= 37) {
            self.currentFGColor = [self ansiColorForCode:n - 30 bright:self.isBold];
        } else if (n == 39) {
            self.currentFGColor = [UIColor blackColor]; // Default
        } else if (n >= 40 && n <= 47) {
            self.currentBGColor = [self ansiColorForCode:n - 40 bright:NO];
        } else if (n == 49) {
            self.currentBGColor = nil; // Default background
        } else if (n >= 90 && n <= 97) {
            self.currentFGColor = [self ansiColorForCode:n - 90 bright:YES];
        } else if (n >= 100 && n <= 107) {
            self.currentBGColor = [self ansiColorForCode:n - 100 bright:YES];
        } else if (n == 38 && i + 2 < parts.count) {
            // Extended foreground color
            int mode = [parts[i + 1] intValue];
            if (mode == 5 && i + 2 < parts.count) {
                // 256 color
                int colorCode = [parts[i + 2] intValue];
                self.currentFGColor = [self color256ForCode:colorCode];
                i += 2;
            } else if (mode == 2 && i + 4 < parts.count) {
                // RGB color
                int r = [parts[i + 2] intValue];
                int g = [parts[i + 3] intValue];
                int b = [parts[i + 4] intValue];
                self.currentFGColor = [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
                i += 4;
            }
        } else if (n == 48 && i + 2 < parts.count) {
            // Extended background color
            int mode = [parts[i + 1] intValue];
            if (mode == 5 && i + 2 < parts.count) {
                int colorCode = [parts[i + 2] intValue];
                self.currentBGColor = [self color256ForCode:colorCode];
                i += 2;
            } else if (mode == 2 && i + 4 < parts.count) {
                int r = [parts[i + 2] intValue];
                int g = [parts[i + 3] intValue];
                int b = [parts[i + 4] intValue];
                self.currentBGColor = [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
                i += 4;
            }
        }
    }
}

- (NSDictionary *)currentAttributes {
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[NSFontAttributeName] = self.isBold ? self.boldFont : self.normalFont;
    attrs[NSForegroundColorAttributeName] = self.currentFGColor ?: [UIColor darkGrayColor];
    if (self.currentBGColor) {
        attrs[NSBackgroundColorAttributeName] = self.currentBGColor;
    }
    return attrs;
}

- (void)flushLineBuffer {
    // Convert line buffer to attributed string and append to output
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] init];
    NSInteger lastNonNull = -1;
    
    // Find last non-null position
    for (NSInteger i = self.lineWidth - 1; i >= 0; i--) {
        if (self.lineBuffer[i] != [NSNull null]) {
            lastNonNull = i;
            break;
        }
    }
    
    if (lastNonNull >= 0) {
        for (NSInteger i = 0; i <= lastNonNull; i++) {
            if (self.lineBuffer[i] == [NSNull null]) {
                // Empty cell - add space
                NSAttributedString *space = [[NSAttributedString alloc] initWithString:@" " attributes:[self currentAttributes]];
                [line appendAttributedString:space];
            } else {
                [line appendAttributedString:self.lineBuffer[i]];
            }
        }
    }
    
    [self.outputBuffer appendAttributedString:line];
    
    // Clear line buffer
    for (NSInteger i = 0; i < self.lineWidth; i++) {
        self.lineBuffer[i] = [NSNull null];
    }
    self.cursorCol = 0;
}

- (void)putChar:(unichar)c {
    if (self.cursorCol >= self.lineWidth) {
        // Line wrap
        [self flushLineBuffer];
        NSAttributedString *newline = [[NSAttributedString alloc] initWithString:@"\n" attributes:[self currentAttributes]];
        [self.outputBuffer appendAttributedString:newline];
    }
    
    NSString *charStr = [NSString stringWithCharacters:&c length:1];
    NSAttributedString *attrChar = [[NSAttributedString alloc] initWithString:charStr attributes:[self currentAttributes]];
    self.lineBuffer[self.cursorCol] = attrChar;
    self.cursorCol++;
}

- (void)appendOutput:(NSString *)text {
    NSMutableString *plainText = [NSMutableString string]; // For password detection
    
    NSUInteger i = 0;
    
    while (i < text.length) {
        unichar c = [text characterAtIndex:i];
        
        if (c == '\x1b' && i + 1 < text.length) {
            unichar nextChar = [text characterAtIndex:i+1];
            
            if (nextChar == '[') {
                // CSI sequence: \x1b[...
                i += 2;
                NSMutableString *code = [NSMutableString string];
                unichar finalChar = 0;
                
                while (i < text.length) {
                    unichar ch = [text characterAtIndex:i];
                    if (ch >= 0x40 && ch <= 0x7E) {
                        finalChar = ch;
                        i++;
                        break;
                    }
                    [code appendFormat:@"%C", ch];
                    i++;
                }
            
            // Handle different escape sequences
            if (finalChar == 'm') {
                // SGR - color/style
                [self parseAnsiCode:code];
            } else if (finalChar == 'C') {
                // CUF - Cursor Forward
                int n = code.length > 0 ? [code intValue] : 1;
                if (n < 1) n = 1;
                self.cursorCol += n;
                if (self.cursorCol > self.lineWidth) self.cursorCol = self.lineWidth;
            } else if (finalChar == 'D') {
                // CUB - Cursor Back
                int n = code.length > 0 ? [code intValue] : 1;
                if (n < 1) n = 1;
                self.cursorCol -= n;
                if (self.cursorCol < 0) self.cursorCol = 0;
            } else if (finalChar == 'G') {
                // CHA - Cursor Horizontal Absolute
                int n = code.length > 0 ? [code intValue] : 1;
                self.cursorCol = n - 1; // 1-based to 0-based
                if (self.cursorCol < 0) self.cursorCol = 0;
                if (self.cursorCol > self.lineWidth) self.cursorCol = self.lineWidth;
            } else if (finalChar == 'K') {
                // EL - Erase in Line: ignore in simple model
                // New content will overwrite anyway
            } else if (finalChar == 'A' || finalChar == 'B') {
                // CUU/CUD - Cursor Up/Down: ignore in our simple model
                // We can't truly move vertically in streaming mode
            } else if (finalChar == 'J') {
                // ED - Erase in Display
                int n = code.length > 0 ? [code intValue] : 0;
                if (n == 2 || n == 3) {
                    // Clear entire screen
                    self.outputBuffer = [[NSMutableAttributedString alloc] init];
                    for (NSInteger j = 0; j < self.lineWidth; j++) {
                        self.lineBuffer[j] = [NSNull null];
                    }
                    self.cursorCol = 0;
                }
            }
            // Ignore other CSI sequences
        } else if (nextChar == ']') {
                // OSC sequence: \x1b]...ST or \x1b]...\x07
                i += 2;
                while (i < text.length) {
                    unichar ch = [text characterAtIndex:i];
                    if (ch == '\x07') { // BEL terminates OSC
                        i++;
                        break;
                    }
                    if (ch == '\x1b' && i + 1 < text.length && [text characterAtIndex:i+1] == '\\') {
                        i += 2; // ST (String Terminator)
                        break;
                    }
                    i++;
                }
            } else if (nextChar == '(' || nextChar == ')') {
                // Character set selection: \x1b(B, \x1b)0, etc.
                i += 3; // Skip ESC, (, and the character set designator
            } else if (nextChar == '7') {
                // DECSC - Save cursor position (ignore)
                i += 2;
            } else if (nextChar == '8') {
                // DECRC - Restore cursor position (ignore)
                i += 2;
            } else if (nextChar == '=' || nextChar == '>') {
                // Application/Normal keypad mode
                i += 2;
            } else if (nextChar == 'M') {
                // Reverse index
                i += 2;
            } else {
                // Unknown ESC sequence - skip ESC and next char
                i += 2;
            }
        } else if (c == '\r') {
            // Carriage return - move to beginning of line
            self.cursorCol = 0;
            i++;
        } else if (c == '\n') {
            // Newline - flush line buffer and start new line
            [self flushLineBuffer];
            NSAttributedString *newline = [[NSAttributedString alloc] initWithString:@"\n" attributes:[self currentAttributes]];
            [self.outputBuffer appendAttributedString:newline];
            i++;
        } else if (c == '\x07' || c == '\x08') {
            // Bell or backspace - ignore bell, handle backspace
            if (c == '\x08' && self.cursorCol > 0) {
                self.cursorCol--;
            }
            i++;
        } else if (c >= 0x20 || c == '\t') {
            // Printable character or tab
            if (c == '\t') {
                // Tab - move to next tab stop (every 8 columns)
                int nextTab = ((int)self.cursorCol / 8 + 1) * 8;
                while (self.cursorCol < nextTab && self.cursorCol < self.lineWidth) {
                    [self putChar:' '];
                }
            } else {
                [self putChar:c];
                [plainText appendFormat:@"%C", c];
            }
            i++;
        } else {
            // Other control characters - skip
            i++;
        }
    }
    
    // Check for password prompt
    NSString *lower = [plainText lowercaseString];
    if ([lower containsString:@"password"] || [lower containsString:@"密码"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isPasswordMode = YES;
            self.inputField.secureTextEntry = YES;
            self.inputField.placeholder = @"Password";
        });
    }
    
    // Limit buffer size (by character count)
    if (self.outputBuffer.length > 50000) {
        [self.outputBuffer deleteCharactersInRange:NSMakeRange(0, self.outputBuffer.length - 40000)];
    }
    
    // Update UI on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        // Build display buffer with current line content
        NSMutableAttributedString *displayBuffer = [self.outputBuffer mutableCopy];
        
        // Append current line buffer content
        NSMutableAttributedString *currentLine = [[NSMutableAttributedString alloc] init];
        NSInteger lastNonNull = -1;
        for (NSInteger j = self.lineWidth - 1; j >= 0; j--) {
            if (self.lineBuffer[j] != [NSNull null]) {
                lastNonNull = j;
                break;
            }
        }
        if (lastNonNull >= 0) {
            for (NSInteger j = 0; j <= lastNonNull; j++) {
                if (self.lineBuffer[j] == [NSNull null]) {
                    NSAttributedString *space = [[NSAttributedString alloc] initWithString:@" " attributes:[self currentAttributes]];
                    [currentLine appendAttributedString:space];
                } else {
                    [currentLine appendAttributedString:self.lineBuffer[j]];
                }
            }
            [displayBuffer appendAttributedString:currentLine];
        }
        
        self.textView.attributedText = displayBuffer;
        // Scroll to bottom
        if (displayBuffer.length > 0) {
            NSRange range = NSMakeRange(displayBuffer.length - 1, 1);
            [self.textView scrollRangeToVisible:range];
        }
    });
}

- (void)startShell {
    
    // Open PTY
    int master, slave;
    char slavePath[PATH_MAX];
    
    if (openpty(&master, &slave, slavePath, NULL, NULL) < 0) {
        [self appendOutput:@"[ERROR: Failed to open PTY]\n"];
        return;
    }
    
    self.masterFD = master;
    
    // Set window size based on calculated dimensions
    struct winsize ws = {.ws_row = 30, .ws_col = (unsigned short)self.lineWidth};
    ioctl(master, TIOCSWINSZ, &ws);
    
    // Find shell - check multiple paths
    // Use sh first - simpler and cleaner output
    NSArray *shells = @[
        @"/bin/sh",
        @"/bin/bash",
        @"/usr/bin/bash",
        @"/var/jb/usr/bin/bash"
    ];
    NSString *shellPath = nil;
    
    for (NSString *s in shells) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:s]) {
            shellPath = s;
            break;
        }
    }
    
    if (!shellPath) {
        [self appendOutput:@"[ERROR: No shell found]\n"];
        return;
    }
    
    // Fork and exec
    pid_t pid = fork();
    
    if (pid < 0) {
        [self appendOutput:@"[ERROR: Fork failed]\n"];
        return;
    }
    
    if (pid == 0) {
        // Child process
        setsid();
        ioctl(slave, TIOCSCTTY, 0);
        
        dup2(slave, STDIN_FILENO);
        dup2(slave, STDOUT_FILENO);
        dup2(slave, STDERR_FILENO);
        
        if (slave > STDERR_FILENO) close(slave);
        close(master);
        
        // Switch to root user
        setgid(0);
        setuid(0);
        
        setenv("TERM", "xterm", 1);
        setenv("LANG", "en_US.UTF-8", 1);
        setenv("HOME", "/var/root", 1);
        setenv("USER", "root", 1);
        setenv("CLICOLOR", "1", 1);
        setenv("PATH", "/usr/local/bin:/var/jb/usr/bin:/var/jb/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", 1);
        setenv("PS1", "# ", 1);
        setenv("ZDOTDIR", "/var/empty", 1);
        
        chdir("/var/root");
        
        char *args[] = {(char *)[shellPath UTF8String], "-f", NULL};
        execve([shellPath UTF8String], args, environ);
        _exit(127);
    }
    
    // Parent process
    self.shellPID = pid;
    close(slave);
    
    // Set non-blocking
    int flags = fcntl(master, F_GETFL);
    fcntl(master, F_SETFL, flags | O_NONBLOCK);
    
    [self appendOutput:@""];
    
    // Read output
    __weak typeof(self) weakSelf = self;
    dispatch_queue_t queue = dispatch_queue_create("terminal.read", DISPATCH_QUEUE_SERIAL);
    self.readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, master, 0, queue);
    
    dispatch_source_set_event_handler(self.readSource, ^{
        char buf[4096];
        ssize_t n = read(master, buf, sizeof(buf) - 1);
        if (n > 0) {
            buf[n] = '\0';
            NSString *str = [[NSString alloc] initWithBytes:buf length:n encoding:NSUTF8StringEncoding];
            if (!str) str = [[NSString alloc] initWithBytes:buf length:n encoding:NSASCIIStringEncoding];
            if (str) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf appendOutput:str];
                });
            }
        }
    });
    
    dispatch_source_set_cancel_handler(self.readSource, ^{
        close(master);
    });
    
    dispatch_resume(self.readSource);
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.readSource) {
        dispatch_source_cancel(self.readSource);
    }
    if (self.shellPID > 0) {
        kill(self.shellPID, SIGTERM);
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.view endEditing:YES];
}

@end

#pragma mark - App Delegate

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // Register custom fonts
    [self registerCustomFonts];
    
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.rootViewController = [[TerminalViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)registerCustomFonts {
    NSBundle *bundle = [NSBundle mainBundle];
    NSArray *fontFiles = @[@"MesloLGS NF Regular.ttf", @"MesloLGS NF Bold.ttf"];
    
    for (NSString *fontFile in fontFiles) {
        NSString *fontPath = [bundle pathForResource:[fontFile stringByDeletingPathExtension] 
                                              ofType:[fontFile pathExtension]
                                         inDirectory:@"Fonts"];
        if (!fontPath) continue;
        
        NSData *fontData = [NSData dataWithContentsOfFile:fontPath];
        if (!fontData) continue;
        
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)fontData);
        CGFontRef font = CGFontCreateWithDataProvider(provider);
        
        if (font) {
            CFErrorRef error = NULL;
            CTFontManagerRegisterGraphicsFont(font, &error);
            CGFontRelease(font);
        }
        CGDataProviderRelease(provider);
    }
}

@end

#pragma mark - Main

int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
