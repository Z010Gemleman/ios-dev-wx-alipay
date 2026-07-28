// VMQLogViewController.m
#import "VMQLogViewController.h"

@interface VMQLogViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<NSDictionary *> *entries;
@property (nonatomic, strong) UISegmentedControl *catSeg;
@end

@implementation VMQLogViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.entries = @[];

    // 分类筛选条（设计文档 §15）
    self.catSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部",@"环境",@"生命",@"通知",@"网络",@"安全"]];
    self.catSeg.selectedSegmentIndex = 0;
    self.catSeg.translatesAutoresizingMaskIntoConstraints = NO;
    [self.catSeg addTarget:self action:@selector(catChanged) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.catSeg];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.catSeg.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.catSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.catSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.tableView.topAnchor constraintEqualToAnchor:self.catSeg.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // 导航栏右侧：清空 + 导出
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(clearTapped)],
        [[UIBarButtonItem alloc] initWithTitle:@"导出" style:UIBarButtonItemStylePlain
                                        target:self action:@selector(exportTapped)],
    ];

    [self reloadLogs];
}

- (void)catChanged { [self reloadLogs]; }

- (void)reloadLogs {
    // 骨架：从 VMQStore 读取；此处仅演示接口，数据为占位。
    // 真机版：NSInteger cat = self.catSeg.selectedSegmentIndex - 1;
    //         self.entries = [[VMQStore sharedStore] readLogsCategory:cat limit:200];
    self.entries = @[
        @{ @"ts": @([[NSDate date] timeIntervalSince1970]), @"level": @(0),
           @"category": @(1), @"message": @"vmqmond 启动（骨架占位）" },
    ];
    [self.tableView reloadData];
}

- (void)clearTapped {
    // [[VMQStore sharedStore] clearLogs];
    self.entries = @[];
    [self.tableView reloadData];
}

- (void)exportTapped {
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *e in self.entries) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:[e[@"ts"] doubleValue]];
        [text appendFormat:@"[%@] cat=%@ lv=%@ %@\n",
         d, e[@"category"], e[@"level"], e[@"message"]];
    }
    UIActivityViewController *av = [[UIActivityViewController alloc]
                                    initWithActivityItems:@[text] applicationActivities:nil];
    [self presentViewController:av animated:YES completion:nil];
}

#pragma mark - UITableViewDataSource
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"log"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                             reuseIdentifier:@"log"];
    NSDictionary *e = self.entries[ip.row];
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:[e[@"ts"] doubleValue]];
    static NSDateFormatter *fmt;
    if (!fmt) { fmt = [NSDateFormatter new]; fmt.dateFormat = @"HH:mm:ss"; }
    cell.textLabel.text = e[@"message"];
    cell.textLabel.font = [UIFont systemFontOfSize:13];
    cell.detailTextLabel.text = [fmt stringFromDate:d];
    return cell;
}

@end
