// Bundled-data toggle mailbox. Both resets must assert together. Sender holds
// payload until a synchronized acknowledgement; receiver samples only after
// the request has crossed two destination clock edges. Intermediate snapshots
// may be coalesced; never use this mailbox for note-on/off event queues.
module bus_snapshot_cdc #(parameter WIDTH=34)(
    input wire src_clk,src_reset_n,
    input wire [WIDTH-1:0] src_data,
    input wire dst_clk,dst_reset_n,
    output reg [WIDTH-1:0] dst_data
);
    reg [WIDTH-1:0] payload,previous;
    reg request,acknowledge;
    (* syn_preserve=1 *) reg ack_meta,ack_sync,req_meta,req_sync;

    // 「有新数据」的判决先单独打一拍。
    //   src_data != previous 是一个 WIDTH 位比较器，它原本直接驱动
    //   payload/previous 两组共 2*WIDTH 个触发器的 CE —— 高扇出 + 长组合链，
    //   实测在 WIDTH=40 时这条 CE 路径 21.6ns（周期 20ns），是全局最差路径。
    //   单独寄存成 1 个 neq_r 之后，比较器只驱动 1 个 D 端，扇出降到 1。
    //   安全性：neq_r 只由 src 域的两个寄存器算出，多一拍延迟不改变
    //   「payload 冻结到 ack 回来」这条不变量 —— 握手往返本身就要 ≥2 个
    //   src 周期 + 2 个 dst 周期，远大于这里多出来的 1 拍。
    reg neq_r;
    always @(posedge src_clk or negedge src_reset_n) begin
        if(!src_reset_n) neq_r<=1'b0;
        else             neq_r<=(src_data!=previous);
    end

    always @(posedge src_clk or negedge src_reset_n) begin
        if(!src_reset_n) begin
            payload<=0;previous<=0;request<=0;ack_meta<=0;ack_sync<=0;
        end else begin
            ack_meta<=acknowledge;ack_sync<=ack_meta;
            if(request==ack_sync && neq_r) begin
                payload<=src_data;previous<=src_data;request<=~request;
            end
        end
    end
    always @(posedge dst_clk or negedge dst_reset_n) begin
        if(!dst_reset_n) begin
            req_meta<=0;req_sync<=0;acknowledge<=0;dst_data<=0;
        end else begin
            req_meta<=request;req_sync<=req_meta;
            if(req_sync!=acknowledge) begin
                dst_data<=payload;acknowledge<=req_sync;
            end
        end
    end
endmodule
